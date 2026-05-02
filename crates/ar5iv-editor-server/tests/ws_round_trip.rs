//! End-to-end test: boot the server, open a WebSocket to /convert,
//! send a TeX fragment, and assert the stub response shape.

use ar5iv_editor::{AppState, convert::Converter, router};
use ar5iv_editor_protocol::{ConvertRequest, ConvertResponse};
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;

#[tokio::test]
async fn ws_convert_round_trips_through_stub() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let state = AppState {
        converter: std::sync::Arc::new(Converter::new(2)),
    };
    let app = router(state);

    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    let url = format!("ws://{addr}/convert");
    let (mut ws, _resp) = tokio_tungstenite::connect_async(url).await.unwrap();

    let req = ConvertRequest {
        id: 42,
        tex: "\\(x^2 + y^2 = z^2\\)".into(),
        preamble: None,
        profile: Some("fragment".into()),
        format: Some("html5".into()),
        preload: vec![],
    };
    ws.send(Message::Text(serde_json::to_string(&req).unwrap().into()))
        .await
        .unwrap();

    let text = loop {
        match ws.next().await.expect("ws closed").unwrap() {
            Message::Text(t) => break t,
            _ => continue,
        }
    };
    let resp: ConvertResponse = serde_json::from_str(text.as_str()).unwrap();
    assert_eq!(resp.id, 42);
    assert_eq!(resp.status_code, 0);
    assert!(resp.result.contains("ar5iv-editor stub"));

    server.abort();
}
