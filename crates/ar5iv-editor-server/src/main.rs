use std::sync::Arc;

use anyhow::Context;
use ar5iv_editor::{AppState, config::Config, convert::Converter, router};
use tower_http::services::ServeDir;
use tracing::info;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,ar5iv_editor=debug".into()),
        )
        .init();

    let cfg = Config::load()?;
    info!(?cfg, "starting ar5iv-editor");

    let state = AppState {
        converter: Arc::new(Converter::new(cfg.max_in_flight)),
    };

    // The library default uses `frontend/dist`; if the user pointed elsewhere
    // via env, layer a fresh ServeDir on top.
    let app = router(state.clone()).nest_service("/static", ServeDir::new(&cfg.static_dir));

    let listener = tokio::net::TcpListener::bind(cfg.bind)
        .await
        .with_context(|| format!("binding {}", cfg.bind))?;
    info!(addr = %cfg.bind, "listening");
    axum::serve(listener, app).await?;
    Ok(())
}
