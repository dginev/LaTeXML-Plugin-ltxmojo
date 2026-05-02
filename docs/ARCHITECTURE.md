# Architecture

This document describes the runtime design of `ar5iv-editor` and the rationale
behind each major choice. Read this first if you want to extend the server,
swap a layer, or understand why a thing is shaped the way it is.

## At a glance

A user types LaTeX in a CodeMirror 6 editor. After 300 ms of quiet, the
frontend sends a JSON `ConvertRequest` over a single, long-lived WebSocket.
The server hands the request to `latexml-oxide` on a blocking thread (gated by
a semaphore) and writes the resulting `ConvertResponse` back over the same
WebSocket. The browser parses the HTML5 fragment and morphs it into the
preview pane with [Idiomorph](https://github.com/bigskysoftware/idiomorph);
native MathML renders the math, with [KaTeX](https://katex.org/) as a
fallback for browsers that don't lay MathML out.

```
                          ┌────────────────────────────────────────┐
                          │          Tokio runtime (server)        │
                          │                                        │
   ┌──────────┐  WS  ┌────┼────┐ spawn_blocking ┌────────────────┐ │
   │ Browser  │ <───>│ ws.rs   │ ──────────────>│ oxide_convert  │ │
   │  CM 6    │      └────┼────┘                │ (sync, CPU)    │ │
   │  Idio-   │           │                     └────────────────┘ │
   │  morph   │           │       cancel oneshot                   │
   └──────────┘           └────────────────────────────────────────┘
```

## Crate split

```
crates/
├── ar5iv-editor-protocol/   serde structs shared by server (and any future
│                            Rust client / TS-bindings generator)
└── ar5iv-editor-server/     Axum binary + lib (bin = `ar5iv-editor`)
```

A separate `protocol` crate lets us:

- vendor the wire types into a future Rust CLI client,
- guarantee server and any downstream Rust consumer agree on the wire shape
  via the type system,
- generate TypeScript bindings (e.g. with `ts-rs`) later if we want to drop
  the hand-written `frontend/src/ws.ts` types.

## Server

### Why Axum 0.8

Native first-class WebSocket support, idiomatic state extraction, clean
error mapping via `IntoResponse`. We use exactly two non-trivial features:
WebSocket upgrade (`axum::extract::ws`) and `tower_http::services::ServeDir`
for static assets.

### Concurrency model

`latexml-oxide` is a synchronous, CPU-bound library. Calling it from an async
task would block a Tokio worker for tens of milliseconds and starve every
other connection. So we:

1. Wrap the call in `tokio::task::spawn_blocking`.
2. Acquire a permit from a global `tokio::sync::Semaphore` *before* spawning,
   so we cap how many blocking workers can be busy converting at once.

The default permit count is `num_cpus::get()`, overridable with
`AR5IV_EDITOR_MAX_IN_FLIGHT`. The semaphore queue applies natural
back-pressure: a flood of requests waits on `acquire_owned()` instead of
inflating the blocking thread pool.

See `crates/ar5iv-editor-server/src/convert.rs`.

### Per-connection request cancellation

Editor input is bursty: the user types a character, we debounce 300 ms, fire a
request, then they type again. That earlier request is now stale. We don't
want its response to overwrite a newer preview.

Frontend mitigates this with monotonic `id`s and discards out-of-order
responses, but the server *also* short-circuits stale work:

- Each in-flight conversion holds a `oneshot` cancel receiver.
- When a new `ConvertRequest` arrives, the server fires the old cancel and
  spawns the new one.
- The blocking conversion itself runs to completion — we don't try to
  preempt CPU-bound work — but its `ConvertResponse` is dropped instead of
  being serialized back over the WebSocket.

See `crates/ar5iv-editor-server/src/ws.rs::handle_socket`.

### Templating

[Askama](https://github.com/askama-rs/askama) — compile-time-checked Jinja-ish
templates. Templates are validated when the server compiles; a typo in
`{{ var }}` is a build error, not a runtime 500. This is overkill for a
four-page app, but it costs nothing and is invariant under future page
growth.

### Error mapping

`error::AppError` is a `thiserror` enum implementing `IntoResponse`. Every
fallible route returns `Result<Response, AppError>`; conversions are via `?`.
Add new variants at the boundary; do not let raw `anyhow::Error` leak into a
response.

## Wire protocol

Single WebSocket at `/convert`. Both directions: JSON text frames, one frame
per logical message.

### `ConvertRequest` (client → server)

```jsonc
{
  "id":       7,                  // u64, monotonic per connection
  "tex":      "\\(x^2 + y^2\\)",  // body fragment
  "preamble": "literal:\\documentclass{article}…",  // optional
  "profile":  "fragment",         // optional, defaults latexml-oxide-side
  "format":   "html5",
  "preload":  ["LaTeX.pool", "amsmath.sty", "..."]
}
```

`tex` is the body fragment to render. If the source contains a full
`\documentclass{...} ... \begin{document}...\end{document}`, the *frontend*
splits the preamble off (`splitPreamble` in `frontend/src/main.ts`) and sends
it as a separate `preamble` field. The `literal:` prefix is honored by
LaTeXML's profile loader — it tells it the value is the preamble text itself,
not a path to load.

### `ConvertResponse` (server → client)

```jsonc
{
  "id":          7,
  "result":      "<div>…</div>",
  "status":      "Status:conversion:0",
  "status_code": 0,             // 0 ok, 1 warn, 2 error, 3 fatal
  "log":         "Status:conversion:0\n…"
}
```

`status_code == 3` means the server gave up — `result` is empty and the UI
shows `log` in place of the preview. Anything else, the UI swaps in
`result` and stashes `log` in the (toggleable) log pane.

### Request id semantics

The server echoes the request `id` on the response. The frontend keeps a
`nextId` counter and ignores any response whose id is less than the highest
already-rendered one. This protects against:

- in-flight responses arriving out of order,
- a stale conversion that outran the cancellation,
- reconnection: after a WebSocket re-open, queued sends keep their original
  ids so the latest still wins.

## Frontend

### Build

Vite + TypeScript. `frontend/vite.config.ts` produces a single
`frontend/dist/main.js` plus a single `frontend/dist/styles.css`. The Axum
server serves that directory at `/static`. In dev, `vite dev` proxies
`/convert`, `/about`, `/help`, `/editor` to the backend on `:3000`.

### Editor

`frontend/src/editor.ts` builds a CodeMirror 6 view with:

- `codemirror-lang-latex` for syntax highlighting,
- `lineNumbers`, `history`, `highlightActiveLine` for ergonomics,
- a `lineWrapping` plugin so long lines don't horizontally scroll,
- one `updateListener` that fires the user's `onChange` callback with the
  document text whenever it changes.

The exposed `EditorHandle` interface deliberately hides every CodeMirror
type. If we ever swap CM6 for Monaco or something else, only `editor.ts`
changes.

### WebSocket client

`frontend/src/ws.ts::ConvertClient` is a small reconnecting client:

- exponential backoff (capped at 8 s),
- queue any sends issued while disconnected; flush on reopen,
- an `onMessage` callback per response, an `onStatus` callback for
  connection state.

It does *not* manage request ids — `main.ts` owns the counter.

### Preview pipeline

`frontend/src/preview.ts::renderResult` parses the server's HTML fragment
into a detached document, then calls `Idiomorph.morph(preview, incoming,
{ morphStyle: "innerHTML" })`. Idiomorph diffs the existing preview tree
against the new tree and only mutates what changed — so caret position,
text-selection, scroll offsets, and CSS transitions all survive a re-render
that would otherwise be a hard `innerHTML =` swap.

After morph, `supportsMathML()` does a one-shot off-screen layout probe
(`<mspace>` height ≥ 5 px). If MathML didn't lay out, we lazy-import KaTeX
and replace each `<math>` node by reading its
`<annotation encoding="application/x-tex">`. The KaTeX bundle is *only*
loaded for browsers that need it (Chromium ≥ 109 ships native MathML, so
most users won't).

## File map

| Path | Purpose |
|------|---------|
| `crates/ar5iv-editor-protocol/src/lib.rs` | `ConvertRequest`, `ConvertResponse`, `ConvertResponse::fatal` helper |
| `crates/ar5iv-editor-server/src/main.rs` | binary entry point — tracing init, config load, bind, serve |
| `crates/ar5iv-editor-server/src/lib.rs` | `AppState`, `router()` — used by `main.rs` and integration tests |
| `crates/ar5iv-editor-server/src/config.rs` | env-var parsing into `Config` |
| `crates/ar5iv-editor-server/src/convert.rs` | `Converter` (semaphore + spawn_blocking), `oxide_convert` stub |
| `crates/ar5iv-editor-server/src/ws.rs` | `/convert` upgrade + per-connection loop with cancellation |
| `crates/ar5iv-editor-server/src/routes.rs` | `/`, `/about`, `/help`, `/editor` handlers |
| `crates/ar5iv-editor-server/src/templates.rs` | Askama `Template` derives |
| `crates/ar5iv-editor-server/src/error.rs` | `AppError` + `IntoResponse` |
| `crates/ar5iv-editor-server/templates/*.html` | Askama HTML templates |
| `crates/ar5iv-editor-server/tests/ws_round_trip.rs` | integration test: real server + tungstenite client |
| `frontend/src/main.ts` | wiring: editor + ws client + debounce + preamble split |
| `frontend/src/editor.ts` | CodeMirror 6 setup, `EditorHandle` |
| `frontend/src/ws.ts` | reconnecting WebSocket client |
| `frontend/src/preview.ts` | Idiomorph swap + MathML/KaTeX fallback |
| `frontend/src/examples.ts` | seed examples for the dropdown |
| `frontend/src/styles.css` | layout (two-pane grid), theme |
| `frontend/index.html` | dev entry; production uses Askama `editor.html` |

## What's intentionally absent

- **No SSE / long polling.** WebSocket gives us a bidirectional path with the
  status-frame semantics LaTeXML naturally produces; SSE was never warranted.
- **No persistent storage.** ltxmojo had user profiles + saved snippets; this
  scaffold doesn't. Adding it back is a clean follow-up — see
  `docs/DEVELOPMENT.md`.
- **No SSR for the editor page.** The `/editor` page renders a static shell
  via Askama; CodeMirror mounts on the client. There's no benefit to
  rendering the editor server-side.
- **No service worker / offline mode.** Conversion is server-side only.

## Trade-offs we intentionally made

- **One WebSocket, no per-request HTTP.** Simpler client, lower latency, but
  it means a backend restart drops every connected user. Acceptable; the
  reconnecting client recovers within a second.
- **`spawn_blocking` over a dedicated thread pool.** Tokio's blocking pool is
  already managed; adding our own would just duplicate machinery. The
  semaphore is the real concurrency knob.
- **Idiomorph instead of a virtual DOM.** A full VDOM (React, Preact) would
  be overkill for one preview pane; `innerHTML` would lose caret/scroll;
  Idiomorph is the middle ground at ~5 KB gzipped.
