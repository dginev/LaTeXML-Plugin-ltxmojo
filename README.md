# ar5iv-editor

A web-based LaTeX editor with a live preview, written in Rust. The successor to
the Perl/Mojolicious [ltxmojo](https://github.com/dginev/LaTeXML-Plugin-ltxmojo).

The browser sends LaTeX source over a WebSocket; the server runs
[`latexml-oxide`](https://github.com/dginev/latexml-oxide) (a pure-Rust
LaTeXML port) and streams back HTML5 + native MathML, which the browser morphs
into the preview pane.

## Run it

Two terminals.

```sh
# 1. Backend (port 3000)
cargo run -p ar5iv-editor-server

# 2. Frontend (Vite dev server on port 5173, proxies WS + routes to :3000)
cd frontend && npm install && npm run dev
```

Open <http://localhost:5173/>. See [Quick start (development)](#quick-start-development)
below for prerequisites, [Production build](#production-build) for a release
binary, and `docs/` for the rest.

## Documentation

- **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** — design, data flow,
  concurrency model, wire protocol, file map, trade-offs.
- **[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)** — dev loop, tests, lint,
  how to wire in real `latexml-oxide`, extension recipes, deployment notes,
  CI starter.

## Status

Early scaffold. The wire protocol, WebSocket plumbing, and editor UI are in
place; `latexml-oxide` is wired in as a stub so the server runs end-to-end
without the private dependency. Replace `oxide_convert` in
`crates/ar5iv-editor-server/src/convert.rs` with a real call once the
`latexml-oxide` crate is added as a dependency
(see [`docs/DEVELOPMENT.md` § Wiring in the real `latexml-oxide`](docs/DEVELOPMENT.md#wiring-in-the-real-latexml-oxide)).

## Stack

| Layer       | Choice                                                       |
|-------------|--------------------------------------------------------------|
| Server      | Rust, [Axum 0.8](https://github.com/tokio-rs/axum) on Tokio  |
| LaTeX→HTML  | `latexml-oxide` via `tokio::task::spawn_blocking`            |
| Templating  | [Askama](https://github.com/askama-rs/askama) (compile-time) |
| Transport   | Single WebSocket at `/convert`, JSON text frames             |
| Editor      | [CodeMirror 6](https://codemirror.net/) + `codemirror-lang-latex` |
| DOM updates | [Idiomorph](https://github.com/bigskysoftware/idiomorph)     |
| Math render | Native browser MathML, KaTeX as a fallback                   |
| Bundler     | Vite + TypeScript                                            |

## Layout

```
ar5iv-editor/
├── Cargo.toml                              workspace
├── crates/
│   ├── ar5iv-editor-protocol/              shared wire types
│   └── ar5iv-editor-server/                Axum binary + lib
│       ├── src/                            main, lib, routes, ws, convert, …
│       └── templates/                      Askama HTML templates
└── frontend/                               Vite + TS + CodeMirror 6
    └── src/                                main, editor, ws, preview, examples
```

## Quick start (development)

Two terminals.

**Backend** (port 3000):

```sh
cargo run -p ar5iv-editor-server
```

**Frontend** (Vite dev server on port 5173, proxies `/convert`, `/about`,
`/help`, `/editor` to the backend):

```sh
cd frontend
npm install
npm run dev
```

Open <http://localhost:5173/>.

## Production build

```sh
cd frontend
npm install
npm run build              # outputs frontend/dist/
cd ..
cargo build -r -p ar5iv-editor-server
./target/release/ar5iv-editor
```

By default the server serves `/static` from `frontend/dist`. Override with
`AR5IV_EDITOR_STATIC_DIR=/path/to/dist`.

### Configuration (env)

| Var                          | Default              | Meaning                                      |
|------------------------------|----------------------|----------------------------------------------|
| `AR5IV_EDITOR_BIND`          | `127.0.0.1:3000`     | Listen address                               |
| `AR5IV_EDITOR_MAX_IN_FLIGHT` | `num_cpus`           | Concurrent conversions (semaphore size)      |
| `AR5IV_EDITOR_STATIC_DIR`    | `frontend/dist`      | Where `/static` is served from               |
| `RUST_LOG`                   | `info,ar5iv_editor=debug` | tracing-subscriber filter               |

## Tests

```sh
cargo test --workspace
```

Includes a WebSocket round-trip integration test that boots the server on a
random port, connects via `tokio-tungstenite`, and asserts the response shape.

## Wire protocol

Single WebSocket at `/convert`; JSON text frames.

Client → server:

```json
{ "id": 7, "tex": "\\(x^2\\)", "preamble": null,
  "profile": "fragment", "format": "html5", "preload": ["..."] }
```

Server → client:

```json
{ "id": 7, "result": "<div>…</div>", "status": "Status:conversion:0",
  "status_code": 0, "log": "…" }
```

When a new request arrives with id `N+1`, the server cancels the result of any
previous in-flight request on the same connection (the underlying conversion
runs to completion; only the response is dropped).

## Roadmap

1. Replace the `oxide_convert` stub with `latexml_oxide::convert(...)`.
2. Port the remaining `examples.js` snippets from ltxmojo.
3. Single-binary deployment via `rust-embed` over `frontend/dist`.
4. Optional: re-add user/profile DB and ZIP archive upload from ltxmojo.

## License

MIT, see `LICENSE`.
