# Development guide

How to set the project up locally, what the dev loop looks like, and how to
extend each layer. Read `docs/ARCHITECTURE.md` first if you haven't.

## Prerequisites

| Tool | Version |
|------|---------|
| `rustc` / `cargo` | edition 2024 — stable ≥ 1.85 |
| `node` | 20 LTS or 22 LTS |
| `npm`  | bundled with node |

No system LaTeX is required — `latexml-oxide` is a pure-Rust port. (Until
it's wired in, the in-tree stub doesn't need anything either.)

## First-time setup

```sh
# server side
cargo build --workspace

# frontend side
cd frontend
npm install
cd ..
```

## Dev loop (two terminals)

**Terminal 1 — backend:**

```sh
RUST_LOG=info,ar5iv_editor=debug cargo run -p ar5iv-editor-server
# → 127.0.0.1:3000
```

The server reloads only when you re-run it. For iterative server work,
[`cargo-watch`](https://crates.io/crates/cargo-watch) is convenient:

```sh
cargo install cargo-watch
cargo watch -x 'run -p ar5iv-editor-server'
```

**Terminal 2 — frontend:**

```sh
cd frontend
npm run dev
# → http://localhost:5173/
```

Vite hot-reloads on every save. The dev server proxies `/convert`,
`/about`, `/help`, `/editor` to the backend (see `frontend/vite.config.ts`),
so you keep using `localhost:5173` as your browser URL.

Open <http://localhost:5173/>.

## Tests

```sh
cargo test --workspace
```

Two layers of tests today:

- **Unit:** `crates/ar5iv-editor-server/src/convert.rs::tests::stub_round_trip`
  exercises the `Converter` directly.
- **Integration:** `crates/ar5iv-editor-server/tests/ws_round_trip.rs`
  binds an OS-assigned port, spawns the real `router()`, opens a WebSocket
  with `tokio-tungstenite`, and asserts the response shape.

To add a new integration test, follow the same shape: build `AppState`, call
`router(state)`, hand it to `axum::serve`, and connect with `tokio-tungstenite`.
Don't introduce a mock HTTP client — exercise the real Axum stack so we
catch upgrade-handshake regressions.

### Frontend type-checking

```sh
cd frontend
npm run typecheck
```

There is no JS test suite yet; preview-pipeline behavior is best caught by
playing with the live UI.

## Lint and format

```sh
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
```

CI (when added) should run both with `-D warnings`.

## Wiring in the real `latexml-oxide`

Right now `crates/ar5iv-editor-server/src/convert.rs::oxide_convert` is a
stub that echoes its input. Two-step swap:

1. Add the real crate as a dependency in
   `crates/ar5iv-editor-server/Cargo.toml`:

   ```toml
   [dependencies]
   latexml-oxide = { git = "ssh://git@github.com/dginev/latexml-oxide.git" }
   # …or path = "../latexml-oxide" while you iterate locally
   ```

2. Replace the body of `oxide_convert` with the real call. Pseudocode:

   ```rust
   fn oxide_convert(req: ConvertRequest) -> ConvertResponse {
       let opts = latexml_oxide::Options {
           profile: req.profile.unwrap_or_else(|| "fragment".into()),
           format:  req.format.unwrap_or_else(|| "html5".into()),
           preamble: req.preamble,
           preload: req.preload,
           // …whichever fields the real Options struct exposes
       };
       match latexml_oxide::convert(&req.tex, &opts) {
           Ok(r) => ConvertResponse {
               id:          req.id,
               result:      r.html,
               status:      r.status,
               status_code: r.status_code,
               log:         r.log,
           },
           Err(e) => ConvertResponse::fatal(req.id, format!("{e}")),
       }
   }
   ```

   Adjust to whatever `latexml-oxide` actually exposes; this signature is a
   placeholder.

3. Drop the `html_escape` helper if the real conversion path doesn't need it.

The stub is kept *deliberately small* so the diff against it is the actual
integration work, no accidental coupling.

## Common extension recipes

### Add a new HTTP route

1. Add a handler in `crates/ar5iv-editor-server/src/routes.rs`.
2. Wire it in `lib.rs::router`:

   ```rust
   .route("/healthz", get(routes::healthz))
   ```

3. If it renders HTML, add an Askama template in `templates/` and a
   `#[derive(Template)]` struct in `src/templates.rs`.

### Add a new field to the wire protocol

1. Edit `crates/ar5iv-editor-protocol/src/lib.rs`. Mark new request fields
   `#[serde(default)]` so old clients still parse.
2. Plumb it through `convert::oxide_convert`.
3. Mirror the field in `frontend/src/ws.ts` (`ConvertRequest` /
   `ConvertResponse` interfaces — kept hand-written for now).
4. If you want a single source of truth, generate the TS types with
   [`ts-rs`](https://crates.io/crates/ts-rs) — open a follow-up.

### Add a new editor example

Edit `frontend/src/examples.ts`. The dropdown is populated from
`Object.keys(EXAMPLES)` in `main.ts::bootExamples`.

### Change the conversion concurrency

Set `AR5IV_EDITOR_MAX_IN_FLIGHT` in the environment, or change the default
in `crates/ar5iv-editor-server/src/config.rs::Config::load`. The server
caps at this many simultaneous blocking workers; everything else queues.

### Re-add user accounts and saved documents

Out of scope for the scaffold; for reference, the Perl ltxmojo did it with
SQLite + `Mojolicious::Plugin::Authentication`. A clean Rust port:

- `sqlx` against SQLite for storage,
- a separate `crates/ar5iv-editor-store` crate so persistence can be unit-
  tested in isolation,
- a `/api/docs` route (HTTP, not WebSocket) for CRUD,
- an additional `Authorization` header check on the WebSocket upgrade.

This is a self-contained add-on; nothing in the current scaffold blocks it.

## Code style

- **No premature abstractions.** Three similar lines beat a helper function
  most of the time. Wait for the fourth before extracting.
- **No comments that just restate the code.** Comment *why*, when the *why*
  is non-obvious — not *what*.
- **Errors at the boundary.** Use `?` and `thiserror::Error` enums; don't
  catch-and-log midway through a function.
- **Trust the framework.** Axum already handles backpressure on response
  bodies; don't add manual buffering.
- **Keep `protocol` minimal.** It is a public type contract — every field
  added there is forever.

## Production build

```sh
cd frontend && npm install && npm run build && cd ..
cargo build --release -p ar5iv-editor-server
./target/release/ar5iv-editor
```

Configuration is via env vars; see `README.md` § Configuration.

### Reverse proxy notes

If you front the server with nginx/Caddy/Traefik, make sure the WebSocket
upgrade headers are forwarded:

```nginx
location /convert {
    proxy_http_version 1.1;
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_pass http://127.0.0.1:3000;
    proxy_read_timeout 1h;     # so idle editor sessions don't drop
}
```

### Single-binary deployment

The current setup serves `frontend/dist` from disk. To produce a single
self-contained binary, add [`rust-embed`](https://crates.io/crates/rust-embed)
and embed `frontend/dist`; replace the `ServeDir` layer with a handler that
reads from the embedded assets. The build script should run
`npm run build` before `cargo build --release`. (Open follow-up.)

## CI suggestion

A single GitHub Actions workflow:

```yaml
# .github/workflows/ci.yml
name: ci
on: [push, pull_request]
jobs:
  rust:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo fmt --all -- --check
      - run: cargo clippy --workspace --all-targets -- -D warnings
      - run: cargo test --workspace --all-targets
  frontend:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm --prefix frontend ci
      - run: npm --prefix frontend run typecheck
      - run: npm --prefix frontend run build
```

## Where to look when something breaks

| Symptom | First file to read |
|---------|-------------------|
| Editor doesn't render preview | `frontend/src/main.ts` (debounce, request id), browser DevTools WS frames |
| Server returns 500 on `/editor` | `crates/ar5iv-editor-server/src/templates.rs` + `templates/editor.html` (Askama compile error?) |
| All conversions hang | `Converter::permits` saturated — check `AR5IV_EDITOR_MAX_IN_FLIGHT` and whether `oxide_convert` is panicking |
| Math renders as raw `<math>` text | MathML probe failed *and* KaTeX dynamic import failed — check Network tab |
| WebSocket immediately closes | `ws.rs::handle_socket` — usually a bad `ConvertRequest` JSON; the server sends a fatal frame and continues |
