//! Wire protocol shared by the ar5iv-editor server and its TypeScript frontend.
//!
//! Frames are JSON text frames over a single WebSocket at `/convert`. Each
//! request carries a monotonic `id`; the server echoes that `id` on the
//! corresponding response so the client can correlate (and discard) results.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConvertRequest {
    pub id: u64,
    pub tex: String,
    #[serde(default)]
    pub preamble: Option<String>,
    #[serde(default)]
    pub profile: Option<String>,
    #[serde(default)]
    pub format: Option<String>,
    #[serde(default)]
    pub preload: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConvertResponse {
    pub id: u64,
    pub result: String,
    pub status: String,
    pub status_code: i32,
    pub log: String,
}

impl ConvertResponse {
    pub fn fatal(id: u64, message: impl Into<String>) -> Self {
        let msg = message.into();
        Self {
            id,
            result: String::new(),
            status: msg.clone(),
            status_code: 3,
            log: msg,
        }
    }
}
