//! Custom JSON event formatter that adds top-level `trace_id`/`span_id`.
//!
//! The stock `tracing_subscriber` JSON formatter (`fmt::layer().json()`) emits
//! the structured log lines Loki parses, but it has no notion of the active
//! OpenTelemetry trace/span. Grafana's Loki→Tempo correlation needs those two
//! ids as top-level fields on every log line so an operator can pivot from a log
//! to the trace that produced it.
//!
//! The built-in `Format<Json>` `FormatEvent` impl is closed (private types), so
//! it cannot be subclassed. [`JsonTraceFormat`] reproduces its output byte-for-
//! byte using only public crates (`serde_json`, `tracing-serde`,
//! `tracing-subscriber`) and inserts `trace_id`/`span_id` (read from the active
//! span's `tracing_opentelemetry::OtelData`) right after `target`. When OTel is
//! disabled there is no `OtelData`, so no trace fields are emitted and the line
//! is identical to the stock formatter.
//!
//! Key order matches stock (`with_target(true)`, `with_thread_ids(true)`,
//! `flatten_event(true)`): `timestamp`, `level`, <flattened event fields>,
//! `target`, `trace_id`, `span_id`, `span`, `spans`, `threadId`.

use std::fmt;
use std::io;
use std::marker::PhantomData;

use serde::ser::{SerializeMap, Serializer as _};
use serde_json::Serializer;
use tracing::{Event, Subscriber};
use tracing_serde::AsSerde;
use tracing_subscriber::fmt::format::Writer;
use tracing_subscriber::fmt::time::{FormatTime, SystemTime};
use tracing_subscriber::fmt::{FmtContext, FormatEvent, FormatFields, FormattedFields};
use tracing_subscriber::registry::{LookupSpan, SpanRef};

/// Event formatter producing stock-compatible JSON plus `trace_id`/`span_id`.
///
/// Wire it in via
/// `fmt::layer().event_format(JsonTraceFormat).fmt_fields(JsonFields::new())` —
/// the `JsonFields` field formatter stores per-span fields as JSON fragments,
/// which this formatter re-parses to rebuild the `span`/`spans` objects exactly
/// like the stock `SerializableSpan`/`SerializableContext`.
#[derive(Debug, Clone, Copy, Default)]
pub struct JsonTraceFormat;

impl<S, N> FormatEvent<S, N> for JsonTraceFormat
where
    S: Subscriber + for<'lookup> LookupSpan<'lookup>,
    N: for<'writer> FormatFields<'writer> + 'static,
{
    fn format_event(
        &self,
        ctx: &FmtContext<'_, S, N>,
        mut writer: Writer<'_>,
        event: &Event<'_>,
    ) -> fmt::Result {
        // Timestamp: same RFC3339-UTC source the stock JSON formatter uses.
        let mut timestamp = String::new();
        SystemTime.format_time(&mut Writer::new(&mut timestamp))?;

        let meta = event.metadata();

        // Current (innermost) span: honour an explicit event parent, else the
        // thread's current span — identical selection to the stock formatter.
        let current_span = event
            .parent()
            .and_then(|id| ctx.span(id))
            .or_else(|| ctx.lookup_current());

        let (trace_id, span_id) = match current_span.as_ref() {
            Some(span) => extract_trace_ids(span),
            None => (None, None),
        };

        let mut visit = || {
            let mut serializer = Serializer::new(WriteAdaptor::new(&mut writer));
            let mut serializer = serializer.serialize_map(None)?;

            serializer.serialize_entry("timestamp", &timestamp)?;
            serializer.serialize_entry("level", &meta.level().as_serde())?;

            // Flatten the event's own fields (incl. `message`) into the root,
            // matching `flatten_event(true)`.
            let mut visitor = tracing_serde::SerdeMapVisitor::new(serializer);
            event.record(&mut visitor);
            let mut serializer = visitor.take_serializer()?;

            serializer.serialize_entry("target", meta.target())?;

            // The only additions over stock: place them right after `target`.
            if let Some(ref t) = trace_id {
                serializer.serialize_entry("trace_id", t)?;
            }
            if let Some(ref s) = span_id {
                serializer.serialize_entry("span_id", s)?;
            }

            let field_marker: PhantomData<N> = PhantomData;
            if let Some(ref span) = current_span {
                // `.unwrap_or(())` mirrors the stock formatter's tolerance of a
                // span whose fields momentarily fail to serialize.
                serializer
                    .serialize_entry("span", &SerializableSpan(span, field_marker))
                    .unwrap_or(());
                serializer.serialize_entry("spans", &SerializableSpans(span, field_marker))?;
            }

            serializer
                .serialize_entry("threadId", &format!("{:?}", std::thread::current().id()))?;

            serializer.end()
        };

        visit().map_err(|_| fmt::Error)?;
        writeln!(writer)
    }
}

/// Read `trace_id`/`span_id` from the span scope's OpenTelemetry data.
///
/// - `span_id` = the current (innermost) span's `OtelData.builder.span_id`, when
///   present and valid.
/// - `trace_id` = the first valid `OtelData.builder.trace_id` walking the scope
///   from innermost outward (the root span holds the generated trace id); if no
///   builder carries one, fall back to the innermost span whose `parent_cx`
///   carries a valid remote trace context (a consumer span that adopted a trace
///   propagated over a message bus).
///
/// Returns `(None, None)` when OTel is disabled (no `OtelData` in extensions),
/// so the log line stays byte-for-byte identical to the stock formatter.
fn extract_trace_ids<S>(span: &SpanRef<'_, S>) -> (Option<String>, Option<String>)
where
    S: for<'lookup> LookupSpan<'lookup>,
{
    use opentelemetry::trace::{SpanId, TraceContextExt, TraceId};
    use tracing_opentelemetry::OtelData;

    let span_id = {
        let ext = span.extensions();
        ext.get::<OtelData>()
            .and_then(|otel| otel.builder.span_id)
            .filter(|s| *s != SpanId::INVALID)
            .map(|s| s.to_string())
    };

    let mut trace_id: Option<String> = None;
    let mut parent_cx_fallback: Option<String> = None;
    for scope_span in span.scope() {
        let ext = scope_span.extensions();
        let Some(otel) = ext.get::<OtelData>() else {
            continue;
        };

        if trace_id.is_none() {
            if let Some(tid) = otel
                .builder
                .trace_id
                .filter(|t| *t != TraceId::INVALID)
            {
                trace_id = Some(tid.to_string());
                break; // innermost valid builder trace id wins; done.
            }
        }

        if parent_cx_fallback.is_none() {
            let remote = otel.parent_cx.span();
            let sc = remote.span_context();
            if sc.is_valid() {
                parent_cx_fallback = Some(sc.trace_id().to_string());
            }
        }
    }

    (trace_id.or(parent_cx_fallback), span_id)
}

/// Serialize one span as `{ <fields...>, "name": <span name> }`, re-parsing the
/// span's stored `FormattedFields` JSON fragment — the stock `SerializableSpan`.
struct SerializableSpan<'a, 'b, S, N>(&'b SpanRef<'a, S>, PhantomData<N>)
where
    S: for<'lookup> LookupSpan<'lookup>,
    N: for<'writer> FormatFields<'writer> + 'static;

impl<S, N> serde::ser::Serialize for SerializableSpan<'_, '_, S, N>
where
    S: for<'lookup> LookupSpan<'lookup>,
    N: for<'writer> FormatFields<'writer> + 'static,
{
    fn serialize<Ser>(&self, serializer: Ser) -> Result<Ser::Ok, Ser::Error>
    where
        Ser: serde::ser::Serializer,
    {
        let mut map = serializer.serialize_map(None)?;

        let ext = self.0.extensions();
        if let Some(fields) = ext.get::<FormattedFields<N>>() {
            // `JsonFields` stores an object fragment (e.g. `{"foo":1}`); re-parse
            // and splice its entries, exactly like the stock formatter.
            match serde_json::from_str::<serde_json::Value>(fields) {
                Ok(serde_json::Value::Object(entries)) => {
                    for (k, v) in entries {
                        map.serialize_entry(&k, &v)?;
                    }
                }
                Ok(value) => {
                    map.serialize_entry("field", &value)?;
                    map.serialize_entry("field_error", "field was not a valid object")?;
                }
                Err(e) => map.serialize_entry("field_error", &e.to_string())?,
            }
        }

        map.serialize_entry("name", self.0.metadata().name())?;
        map.end()
    }
}

/// Serialize the whole span scope as a list in root→current order — the stock
/// `SerializableContext`.
struct SerializableSpans<'a, 'b, S, N>(&'b SpanRef<'a, S>, PhantomData<N>)
where
    S: for<'lookup> LookupSpan<'lookup>,
    N: for<'writer> FormatFields<'writer> + 'static;

impl<S, N> serde::ser::Serialize for SerializableSpans<'_, '_, S, N>
where
    S: for<'lookup> LookupSpan<'lookup>,
    N: for<'writer> FormatFields<'writer> + 'static,
{
    fn serialize<Ser>(&self, serializer: Ser) -> Result<Ser::Ok, Ser::Error>
    where
        Ser: serde::ser::Serializer,
    {
        use serde::ser::SerializeSeq as _;
        let mut seq = serializer.serialize_seq(None)?;
        for span in self.0.scope().from_root() {
            seq.serialize_element(&SerializableSpan::<S, N>(&span, PhantomData))?;
        }
        seq.end()
    }
}

/// Bridges `serde_json`'s `io::Write` serializer onto the `fmt::Write` sink the
/// formatter is handed — a public reimplementation of the crate-private
/// `tracing_subscriber::fmt::writer::WriteAdaptor`.
struct WriteAdaptor<'a> {
    fmt_write: &'a mut dyn fmt::Write,
}

impl<'a> WriteAdaptor<'a> {
    fn new(fmt_write: &'a mut dyn fmt::Write) -> Self {
        Self { fmt_write }
    }
}

impl io::Write for WriteAdaptor<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let s = std::str::from_utf8(buf)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.fmt_write
            .write_str(s)
            .map_err(io::Error::other)?;
        Ok(s.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::JsonTraceFormat;

    use std::io;
    use std::sync::{Arc, Mutex};

    use opentelemetry::trace::TracerProvider as _;
    use opentelemetry_sdk::propagation::TraceContextPropagator;
    use opentelemetry_sdk::trace::SdkTracerProvider;
    use tracing_subscriber::fmt::format::JsonFields;
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::Registry;

    /// A `MakeWriter` that captures every line into a shared buffer.
    #[derive(Clone)]
    struct BufWriter(Arc<Mutex<Vec<u8>>>);

    impl io::Write for BufWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for BufWriter {
        type Writer = BufWriter;
        fn make_writer(&'a self) -> Self::Writer {
            self.clone()
        }
    }

    fn fmt_layer<S>(buf: Arc<Mutex<Vec<u8>>>) -> impl tracing_subscriber::Layer<S>
    where
        S: tracing::Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
    {
        tracing_subscriber::fmt::layer()
            .event_format(JsonTraceFormat)
            .fmt_fields(JsonFields::new())
            .with_writer(BufWriter(buf))
    }

    fn captured_lines(buf: &Arc<Mutex<Vec<u8>>>) -> Vec<serde_json::Value> {
        let bytes = buf.lock().unwrap().clone();
        String::from_utf8(bytes)
            .unwrap()
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).expect("each log line must be valid JSON"))
            .collect()
    }

    #[test]
    fn emits_trace_and_span_ids_with_otel() {
        let provider = SdkTracerProvider::builder().build();
        opentelemetry::global::set_tracer_provider(provider.clone());
        opentelemetry::global::set_text_map_propagator(TraceContextPropagator::new());

        let otel_layer =
            tracing_opentelemetry::layer().with_tracer(provider.tracer("test"));

        let buf = Arc::new(Mutex::new(Vec::new()));
        let subscriber = Registry::default()
            .with(otel_layer)
            .with(fmt_layer(buf.clone()));

        tracing::subscriber::with_default(subscriber, || {
            tracing::info_span!("test_span", foo = 1)
                .in_scope(|| tracing::info!(message = "hello", k = "v"));
        });

        provider.force_flush().ok();

        let lines = captured_lines(&buf);
        assert!(!lines.is_empty(), "expected at least one log line");
        let line = &lines[0];

        // Preserved stock keys.
        for key in ["timestamp", "level", "target", "message", "spans"] {
            assert!(line.get(key).is_some(), "missing key `{key}` in {line}");
        }

        // Flattened event fields at the top level.
        assert_eq!(line["message"], "hello");
        assert_eq!(line["k"], "v");

        // Span list carries the instrumented span.
        assert_eq!(line["spans"][0]["name"], "test_span");

        // The two new fields.
        let trace_id = line["trace_id"]
            .as_str()
            .expect("trace_id must be a string");
        assert_eq!(trace_id.len(), 32, "trace_id must be 32 hex chars");
        assert!(
            trace_id.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "trace_id must be lowercase hex: {trace_id}"
        );
        assert_ne!(trace_id, "0".repeat(32), "trace_id must be non-zero");

        let span_id = line["span_id"].as_str().expect("span_id must be a string");
        assert_eq!(span_id.len(), 16, "span_id must be 16 hex chars");
        assert!(
            span_id.chars().all(|c| c.is_ascii_hexdigit()),
            "span_id must be hex: {span_id}"
        );
    }

    #[test]
    fn logging_only_has_no_trace_id() {
        // No otel layer / no provider installed on this subscriber.
        let buf = Arc::new(Mutex::new(Vec::new()));
        let subscriber = Registry::default().with(fmt_layer(buf.clone()));

        tracing::subscriber::with_default(subscriber, || {
            tracing::info_span!("plain_span", foo = 2)
                .in_scope(|| tracing::info!(message = "no-otel", k = "v"));
        });

        let lines = captured_lines(&buf);
        assert!(!lines.is_empty(), "expected at least one log line");
        let line = &lines[0];

        // Valid JSON, stock keys intact, event fields flattened.
        assert_eq!(line["message"], "no-otel");
        assert_eq!(line["k"], "v");
        assert_eq!(line["spans"][0]["name"], "plain_span");
        for key in ["timestamp", "level", "target"] {
            assert!(line.get(key).is_some(), "missing key `{key}`");
        }

        // No trace correlation fields without OTel.
        assert!(line.get("trace_id").is_none(), "trace_id must be absent");
        assert!(line.get("span_id").is_none(), "span_id must be absent");
    }
}
