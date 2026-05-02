use axum::{
    extract::{
        State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::{mpsc, oneshot};
use tracing::{debug, warn};

use ar5iv_editor_protocol::{ConvertRequest, ConvertResponse};

use crate::AppState;



pub async fn ws_handler(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut sender, mut receiver) = socket.split();
    let (resp_tx, mut resp_rx) = mpsc::channel::<ConvertResponse>(16);

    let send_task = tokio::spawn(async move {
        while let Some(resp) = resp_rx.recv().await {
            let payload = match serde_json::to_string(&resp) {
                Ok(s) => s,
                Err(e) => {
                    warn!(error = %e, "failed to serialize response");
                    continue;
                }
            };
            if sender.send(Message::Text(payload.into())).await.is_err() {
                break;
            }
        }
    });

    let mut active_cancel: Option<oneshot::Sender<()>> = None;

    while let Some(Ok(msg)) = receiver.next().await {
        match msg {
            Message::Text(text) => {
                let req: ConvertRequest = match serde_json::from_str(text.as_str()) {
                    Ok(r) => r,
                    Err(e) => {
                        let _ = resp_tx
                            .send(ConvertResponse::fatal(0, format!("bad request: {e}")))
                            .await;
                        continue;
                    }
                };
                let id = req.id;

                if let Some(prev) = active_cancel.take() {
                    let _ = prev.send(());
                }
                let (cancel_tx, cancel_rx) = oneshot::channel();
                active_cancel = Some(cancel_tx);

                let converter = state.converter.clone();
                let resp_tx = resp_tx.clone();
                tokio::spawn(async move {
                    tokio::select! {
                        resp = converter.convert(req) => {
                            let _ = resp_tx.send(resp).await;
                        }
                        _ = cancel_rx => {
                            debug!(id, "request superseded by newer one");
                        }
                    }
                });
            }
            Message::Close(_) => break,
            Message::Binary(_) | Message::Ping(_) | Message::Pong(_) => {}
        }
    }

    if let Some(prev) = active_cancel.take() {
        let _ = prev.send(());
    }
    drop(resp_tx);
    let _ = send_task.await;
}
