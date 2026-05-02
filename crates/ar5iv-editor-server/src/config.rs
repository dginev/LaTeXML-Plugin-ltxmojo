use std::{net::SocketAddr, path::PathBuf};

#[derive(Debug, Clone)]
pub struct Config {
    pub bind: SocketAddr,
    pub max_in_flight: usize,
    pub static_dir: PathBuf,
}

impl Config {
    pub fn load() -> anyhow::Result<Self> {
        let bind = std::env::var("AR5IV_EDITOR_BIND")
            .ok()
            .map(|s| s.parse())
            .transpose()?
            .unwrap_or_else(|| "127.0.0.1:3000".parse().expect("static default"));
        let max_in_flight = std::env::var("AR5IV_EDITOR_MAX_IN_FLIGHT")
            .ok()
            .map(|s| s.parse())
            .transpose()?
            .unwrap_or_else(num_cpus::get);
        let static_dir = std::env::var("AR5IV_EDITOR_STATIC_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("frontend/dist"));
        Ok(Self { bind, max_in_flight, static_dir })
    }
}
