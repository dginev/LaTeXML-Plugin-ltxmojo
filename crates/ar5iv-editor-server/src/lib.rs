//! Library half of the ar5iv-editor server. The binary in `main.rs` is a
//! thin wrapper; integration tests build the same router via `router()`.

pub mod config;
pub mod convert;
pub mod error;
pub mod routes;
pub mod templates;
pub mod ws;

use std::sync::Arc;

use axum::{
    Router,
    routing::{any, get},
};
use tower_http::{services::ServeDir, trace::TraceLayer};

use crate::convert::Converter;

#[derive(Clone)]
pub struct AppState {
    pub converter: Arc<Converter>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(routes::index))
        .route("/about", get(routes::about))
        .route("/help", get(routes::help))
        .route("/editor", get(routes::editor))
        .route("/convert", any(ws::ws_handler))
        .nest_service("/static", ServeDir::new("frontend/dist"))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
