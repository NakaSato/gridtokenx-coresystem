//! Shared telemetry initialization for GridTokenX services.
//!
//! Unifies the per-service `init_telemetry` copies that previously lived in
//! aggregator-bridge, trading-service, iam-service, noti-service and chain-bridge.
//! Provides env-filtered structured logging — JSON by default (the documented
//! service standard), `LOG_FORMAT=pretty` for human-readable dev output.
//!
//! Returns a [`TelemetryGuard`]; services needing teardown call `.shutdown()`,
//! others may drop it.

use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

/// Guard for telemetry lifecycle.
///
/// Logging-only setup needs no teardown today; the type exists so callers keep
/// a handle for future flush-on-shutdown logic (e.g. an OTLP span exporter).
#[derive(Debug)]
pub struct TelemetryGuard {
    _private: (),
}

impl TelemetryGuard {
    /// Flush and shut down telemetry. No-op for the current logging-only setup.
    pub fn shutdown(&self) {}
}

/// Initialize the global tracing subscriber for `service_name`.
///
/// Filter comes from `RUST_LOG` (default `info`). Format from `LOG_FORMAT`:
/// `json` (default) or `pretty`/`text` for non-JSON dev output.
///
/// Must be called once per process; a second call is a no-op because the global
/// subscriber is already set (the underlying `try_init` would error, which is
/// swallowed here).
pub fn init(service_name: &str) -> TelemetryGuard {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let pretty = matches!(
        std::env::var("LOG_FORMAT").as_deref(),
        Ok("pretty") | Ok("text")
    );

    let registry = tracing_subscriber::registry().with(filter);
    let initialized = if pretty {
        registry
            .with(tracing_subscriber::fmt::layer().with_target(true))
            .try_init()
            .is_ok()
    } else {
        registry
            .with(
                tracing_subscriber::fmt::layer()
                    .json()
                    .with_target(true)
                    .with_thread_ids(true)
                    .flatten_event(true),
            )
            .try_init()
            .is_ok()
    };

    if initialized {
        tracing::info!(service = service_name, "telemetry initialized");
    }
    TelemetryGuard { _private: () }
}

/// Backward-compatible alias for [`init`], matching the old per-service name.
pub fn init_telemetry(service_name: &str) -> TelemetryGuard {
    init(service_name)
}

/// Backward-compatible shutdown helper for the old per-service API.
pub fn shutdown_telemetry(guard: &TelemetryGuard) {
    guard.shutdown();
}
