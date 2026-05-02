use std::sync::Arc;

use ar5iv_editor_protocol::{ConvertRequest, ConvertResponse};
use tokio::sync::Semaphore;
use tracing::error;

pub struct Converter {
    permits: Arc<Semaphore>,
}

impl Converter {
    pub fn new(max_in_flight: usize) -> Self {
        Self {
            permits: Arc::new(Semaphore::new(max_in_flight.max(1))),
        }
    }

    pub async fn convert(&self, req: ConvertRequest) -> ConvertResponse {
        let id = req.id;
        let permit = match self.permits.clone().acquire_owned().await {
            Ok(p) => p,
            Err(_) => return ConvertResponse::fatal(id, "converter shutting down"),
        };
        let join = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            oxide_convert(req)
        })
        .await;
        match join {
            Ok(resp) => resp,
            Err(e) => {
                error!(error = %e, "conversion task panicked");
                ConvertResponse::fatal(id, format!("internal conversion failure: {e}"))
            }
        }
    }
}

// Stub. Replace with `latexml_oxide::convert(...)` once the private crate is wired in.
fn oxide_convert(req: ConvertRequest) -> ConvertResponse {
    let html = format!(
        "<div class=\"ar5iv-stub\"><p><em>ar5iv-editor stub:</em> latexml-oxide is not wired in yet. \
         The server received {} bytes of TeX and echoed them back unparsed.</p>\
         <pre>{}</pre></div>",
        req.tex.len(),
        html_escape(&req.tex)
    );
    ConvertResponse {
        id: req.id,
        result: html,
        status: "Status:conversion:0 (stub)".into(),
        status_code: 0,
        log: "Status:conversion:0\nStub conversion; no LaTeX was actually parsed.".into(),
    }
}

fn html_escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for c in input.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn stub_round_trip() {
        let c = Converter::new(2);
        let resp = c
            .convert(ConvertRequest {
                id: 7,
                tex: "\\(x^2\\)".into(),
                preamble: None,
                profile: None,
                format: None,
                preload: vec![],
            })
            .await;
        assert_eq!(resp.id, 7);
        assert_eq!(resp.status_code, 0);
        assert!(resp.result.contains("x^2") || resp.result.contains("x^2"));
    }
}
