use axum::{routing::get, Router, response::Json};
use serde_json::json;
use std::net::SocketAddr;
use std::env;

#[tokio::main]
async fn main() {
    let port: u16 = env::var("PORT")
        .unwrap_or_else(|_| "8080".to_string())
        .parse()
        .expect("Invalid PORT");

    let addr = SocketAddr::from(([0, 0, 0, 0], port));

    let app = Router::new()
        .route("/", get(root))
        .route("/health", get(health));

    println!("Server running on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn root() -> &'static str {
    "dumb-server"
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({"status": "ok"}))
}