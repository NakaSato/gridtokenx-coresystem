//! Shared telemetry initialization for GridTokenX services.
//!
//! Unifies the per-service `init_telemetry` copies that previously lived in
//! aggregator-bridge, trading-service, iam-service, noti-service and chain-bridge.
//! Provides env-filtered structured logging — JSON by default (the documented
//! service standard), `LOG_FORMAT=pretty` for human-readable dev output.
//!
//! Returns a [`TelemetryGuard`]; services needing teardown call `.shutdown()`,
//! others may drop it.

use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::trace::SdkTracerProvider;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

mod json_format;
pub mod time;

use json_format::JsonTraceFormat;

/// Guard for telemetry lifecycle.
///
/// Holds the OTLP tracer provider (when tracing is enabled) so spans are flushed
/// on shutdown. Logging-only setups carry `None` and need no teardown.
#[derive(Debug)]
pub struct TelemetryGuard {
    provider: Option<SdkTracerProvider>,
}

impl TelemetryGuard {
    /// Flush and shut down telemetry. Flushes any buffered OTLP spans; a no-op
    /// when tracing was not enabled.
    pub fn shutdown(&self) {
        if let Some(provider) = &self.provider {
            if let Err(e) = provider.force_flush() {
                eprintln!("gridtokenx-telemetry: span flush on shutdown failed: {e:?}");
            }
            if let Err(e) = provider.shutdown() {
                eprintln!("gridtokenx-telemetry: tracer shutdown failed: {e:?}");
            }
        }
    }
}

impl Drop for TelemetryGuard {
    fn drop(&mut self) {
        // Best-effort flush only — never shut the provider down here. Many call
        // sites discard the guard (`init_telemetry(...)` as a bare statement);
        // the tracer provider is kept alive by the global registry regardless, so
        // a discarded guard must NOT tear tracing down. Shutdown is explicit, via
        // `shutdown()`, for callers that hold the guard to process end.
        if let Some(provider) = &self.provider {
            let _ = provider.force_flush();
        }
    }
}

/// Builds an OTLP-over-HTTP tracer provider exporting to `endpoint` (batch,
/// background thread). Returns `None` on any exporter build failure — tracing is
/// best-effort and must never take down the service.
fn build_tracer_provider(service_name: &str, endpoint: &str) -> Option<SdkTracerProvider> {
    // Per-signal traces endpoint. The base OTEL_EXPORTER_OTLP_ENDPOINT gets the
    // standard `/v1/traces` suffix appended for the HTTP transport.
    let traces_endpoint = format!("{}/v1/traces", endpoint.trim_end_matches('/'));

    let exporter = match opentelemetry_otlp::SpanExporter::builder()
        .with_http()
        .with_endpoint(traces_endpoint)
        .build()
    {
        Ok(e) => e,
        Err(e) => {
            eprintln!("gridtokenx-telemetry: OTLP exporter build failed ({e}); tracing disabled");
            return None;
        }
    };

    let resource = opentelemetry_sdk::Resource::builder()
        .with_service_name(service_name.to_string())
        .build();

    Some(
        SdkTracerProvider::builder()
            .with_batch_exporter(exporter)
            .with_resource(resource)
            .build(),
    )
}

/// Initialize the global tracing subscriber for `service_name`.
///
/// Filter comes from `RUST_LOG` (default `info`). Format from `LOG_FORMAT`:
/// `json` (default) or `pretty`/`text` for non-JSON dev output.
///
/// Must be called once per process; a second call is a no-op because the global
/// subscriber is already set. That expected case, and any other `try_init`
/// failure, is non-fatal (callers get a valid guard either way) but is always
/// reported to stderr — never silent, since a failed init means every
/// `tracing::*!` call below (including this function's own success log) is a
/// no-op, so the failure can't be observed through tracing itself.
pub fn init(service_name: &str) -> TelemetryGuard {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let pretty = matches!(
        std::env::var("LOG_FORMAT").as_deref(),
        Ok("pretty") | Ok("text")
    );

    // Optional OTLP tracing layer — enabled only when an endpoint is configured.
    // Absent/empty endpoint keeps the historical logging-only behaviour so
    // services run unchanged outside the compose/observability stack.
    let provider = match std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT") {
        Ok(endpoint) if !endpoint.trim().is_empty() => {
            build_tracer_provider(service_name, endpoint.trim())
        }
        _ => None,
    };
    let otel_layer = provider.as_ref().map(|provider| {
        use opentelemetry::trace::TracerProvider as _;
        // W3C `traceparent` propagation so trace context crosses service hops
        // (HTTP headers, NATS/Kafka message headers).
        opentelemetry::global::set_text_map_propagator(
            opentelemetry_sdk::propagation::TraceContextPropagator::new(),
        );
        opentelemetry::global::set_tracer_provider(provider.clone());
        tracing_opentelemetry::layer().with_tracer(provider.tracer("gridtokenx"))
    });

    // `Option<Layer>` implements `Layer`, so this adds the OTel layer when present
    // and is inert otherwise.
    let registry = tracing_subscriber::registry().with(filter).with(otel_layer);
    let result = if pretty {
        registry
            .with(tracing_subscriber::fmt::layer().with_target(true))
            .try_init()
            .map_err(|e| e.to_string())
    } else {
        // Custom JSON formatter: stock `fmt().json().with_target(true)
        // .with_thread_ids(true).flatten_event(true)` output, plus top-level
        // `trace_id`/`span_id` for Loki→Tempo correlation. `JsonFields` stores
        // per-span fields as JSON fragments the formatter re-parses to rebuild
        // the `span`/`spans` objects. When OTel is disabled the trace fields are
        // simply omitted, leaving the line identical to the stock formatter.
        registry
            .with(
                tracing_subscriber::fmt::layer()
                    .event_format(JsonTraceFormat)
                    .fmt_fields(tracing_subscriber::fmt::format::JsonFields::new()),
            )
            .try_init()
            .map_err(|e| e.to_string())
    };

    match result {
        Ok(()) => tracing::info!(
            service = service_name,
            tracing_enabled = provider.is_some(),
            "telemetry initialized"
        ),
        Err(e) => eprintln!(
            "gridtokenx-telemetry: init({service_name}) failed, tracing is NOT active for this process: {e}"
        ),
    }
    TelemetryGuard { provider }
}

/// Inject the current span's W3C trace context (`traceparent`/`tracestate`) into a
/// carrier via `set(key, value)`.
///
/// Lets callers propagate trace context across a message bus without depending on
/// `opentelemetry` themselves — e.g. writing into an `async_nats::HeaderMap`:
/// `inject_trace_context(|k, v| headers.insert(k, v.as_str()))`. A no-op when
/// tracing is disabled (the global propagator is then the noop propagator).
pub fn inject_trace_context<F: FnMut(&str, String)>(set: F) {
    use opentelemetry::propagation::Injector;
    use tracing_opentelemetry::OpenTelemetrySpanExt;

    struct ClosureInjector<F>(F);
    impl<F: FnMut(&str, String)> Injector for ClosureInjector<F> {
        fn set(&mut self, key: &str, value: String) {
            (self.0)(key, value);
        }
    }

    let cx = tracing::Span::current().context();
    let mut injector = ClosureInjector(set);
    opentelemetry::global::get_text_map_propagator(|prop| prop.inject_context(&cx, &mut injector));
}

/// Set `span`'s parent from W3C trace headers collected off a message bus.
///
/// The caller pulls the `traceparent`/`tracestate` headers into a map (out of an
/// `async_nats` message, Kafka record, etc.) and passes them here; the extracted
/// remote context becomes `span`'s parent, stitching the consumer span onto the
/// producer's trace. A no-op when the headers carry no context.
pub fn set_parent_from_headers(
    span: &tracing::Span,
    headers: &std::collections::HashMap<String, String>,
) {
    use opentelemetry::propagation::Extractor;
    use tracing_opentelemetry::OpenTelemetrySpanExt;

    struct MapExtractor<'a>(&'a std::collections::HashMap<String, String>);
    impl Extractor for MapExtractor<'_> {
        fn get(&self, key: &str) -> Option<&str> {
            self.0.get(key).map(String::as_str)
        }
        fn keys(&self) -> Vec<&str> {
            self.0.keys().map(String::as_str).collect()
        }
    }

    let parent =
        opentelemetry::global::get_text_map_propagator(|prop| prop.extract(&MapExtractor(headers)));
    span.set_parent(parent);
}

/// Backward-compatible alias for [`init`], matching the old per-service name.
pub fn init_telemetry(service_name: &str) -> TelemetryGuard {
    init(service_name)
}

/// Backward-compatible shutdown helper for the old per-service API.
pub fn shutdown_telemetry(guard: &TelemetryGuard) {
    guard.shutdown();
}
