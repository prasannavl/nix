use std::{net::SocketAddr, sync::Arc};

use anyhow::{Context, Result};
use async_nats::{
    jetstream::{self, stream::StorageType},
    Client,
};
use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::{postgres::PgPoolOptions, PgPool};
use tower_http::trace::TraceLayer;
use tracing::info;

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing();

    let config = Config::from_env();
    let state = Arc::new(AppState::connect(config).await?);
    let app = build_router(state.clone());
    let listener = tokio::net::TcpListener::bind(state.config.bind_addr)
        .await
        .context("failed to bind HTTP listener")?;

    info!(addr = %state.config.bind_addr, "srv-ingest listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("axum server exited with error")
}

fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "gap3_api_chat=info,tower_http=info".into()),
        )
        .with_target(false)
        .compact()
        .init();
}

fn build_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/v1/ingest/messages", post(ingest_message))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn healthz() -> impl IntoResponse {
    StatusCode::OK
}

async fn readyz(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let db_ok = sqlx::query_scalar::<_, i64>("select 1")
        .fetch_one(&state.postgres)
        .await
        .is_ok();
    let nats_ok = state
        .jetstream
        .get_stream(&state.config.nats_stream)
        .await
        .is_ok();

    if db_ok && nats_ok {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    }
}

async fn ingest_message(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<IngestEnvelope>,
) -> Result<impl IntoResponse, AppError> {
    let body = serde_json::to_vec(&payload).context("failed to serialize ingest payload")?;
    let ack = state
        .jetstream
        .publish(state.config.nats_subject.clone(), body.into())
        .await
        .context("failed to publish ingest event")?
        .await
        .context("failed waiting for JetStream publish ack")?;

    let response = IngestAccepted {
        stream: ack.stream,
        sequence: ack.sequence,
        dedupe: ack.duplicate,
    };

    Ok((StatusCode::ACCEPTED, Json(response)))
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            let _ = signal.recv().await;
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
}

#[derive(Clone)]
struct Config {
    bind_addr: SocketAddr,
    postgres_url: String,
    nats_url: String,
    nats_stream: String,
    nats_subject: String,
}

impl Config {
    fn from_env() -> Self {
        Self {
            bind_addr: read_env("GAP3_API_INGEST_BIND_ADDR", "0.0.0.0:3000")
                .parse()
                .expect("invalid GAP3_API_INGEST_BIND_ADDR"),
            postgres_url: read_env(
                "GAP3_API_INGEST_POSTGRES_URL",
                "postgres://postgres@127.0.0.1:5432/gap3",
            ),
            nats_url: read_env("GAP3_API_INGEST_NATS_URL", "nats://127.0.0.1:4222"),
            nats_stream: read_env("GAP3_API_INGEST_NATS_STREAM", "GAP3_INGEST"),
            nats_subject: read_env("GAP3_API_INGEST_NATS_SUBJECT", "ingest.whatsapp.raw"),
        }
    }
}

fn read_env(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.to_owned())
}

struct AppState {
    config: Config,
    postgres: PgPool,
    _nats: Client,
    jetstream: jetstream::Context,
}

impl AppState {
    async fn connect(config: Config) -> Result<Self> {
        let postgres = PgPoolOptions::new()
            .max_connections(5)
            .connect(&config.postgres_url)
            .await
            .context("failed to connect to postgres")?;
        let nats = async_nats::connect(&config.nats_url)
            .await
            .context("failed to connect to nats")?;
        let jetstream = jetstream::new(nats.clone());

        ensure_stream(&jetstream, &config.nats_stream, &config.nats_subject).await?;

        Ok(Self {
            config,
            postgres,
            _nats: nats,
            jetstream,
        })
    }
}

async fn ensure_stream(
    jetstream: &jetstream::Context,
    stream_name: &str,
    subject: &str,
) -> Result<()> {
    if jetstream.get_stream(stream_name).await.is_ok() {
        return Ok(());
    }

    jetstream
        .create_stream(jetstream::stream::Config {
            name: stream_name.to_owned(),
            subjects: vec![subject.to_owned()],
            storage: StorageType::File,
            ..Default::default()
        })
        .await
        .with_context(|| format!("failed to create JetStream stream {stream_name}"))?;

    Ok(())
}

#[derive(Debug, Deserialize, Serialize)]
struct IngestEnvelope {
    source: String,
    tenant_id: String,
    event_id: String,
    payload: serde_json::Value,
}

#[derive(Debug, Serialize)]
struct IngestAccepted {
    stream: String,
    sequence: u64,
    dedupe: bool,
}

struct AppError(anyhow::Error);

impl<E> From<E> for AppError
where
    E: Into<anyhow::Error>,
{
    fn from(error: E) -> Self {
        Self(error.into())
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
        tracing::error!(error = ?self.0, "request failed");
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({
                "error": "internal_server_error",
            })),
        )
            .into_response()
    }
}
