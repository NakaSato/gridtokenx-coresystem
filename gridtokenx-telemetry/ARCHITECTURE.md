# gridtokenx-telemetry — Architecture

> Shared telemetry initialization (structured `tracing`) for GridTokenX services. A small Rust
> library crate consumed by the backend services. This doc covers **only** the contents of this
> folder.

---

## 1. What This Is

`gridtokenx-telemetry` is a **shared Rust library crate** (no binary). It unifies the per-service
`init_telemetry` copies that previously lived independently in aggregator-bridge, trading-service,
iam-service, noti-service, and chain-bridge — one place to configure structured logging so every
service emits the same shape.

It is tracked **directly in the superproject** (not a git submodule), unlike the `gridtokenx-*`
service repos.

Crate: `gridtokenx-telemetry` v0.1.0, edition 2021. Dependencies: `tracing` +
`tracing-subscriber` (`env-filter`, `json`, `fmt`).

## 2. Module Layout

```
src/
└── lib.rs    the entire crate — TelemetryGuard + init / shutdown
Cargo.toml
```

## 3. Public API

| Item | Purpose |
| :--- | :--- |
| `init(service_name: &str) -> TelemetryGuard` | Initialize structured logging; returns a guard |
| `init_telemetry(service_name: &str) -> TelemetryGuard` | Back-compat alias for `init` |
| `TelemetryGuard` | Held by the caller for the process lifetime |
| `shutdown_telemetry(guard: &TelemetryGuard)` | Explicit teardown for services that need it |

Services needing teardown call `guard.shutdown()`; others may simply drop the guard.

## 4. Behavior

- **Structured logging** via `tracing-subscriber`, env-filtered (`RUST_LOG`-style via `env-filter`).
- **JSON by default** — the documented service-wide logging standard.
- **`LOG_FORMAT=pretty`** switches to human-readable output for local dev.

This matches the platform logging convention: `tracing` (not `log`), structured JSON, so logs are
machine-parseable across the mesh.

## 5. Usage

```rust
// In a service's main(), before doing work:
let _guard = gridtokenx_telemetry::init("aggregator-bridge");
// ... run the service; drop _guard (or call shutdown) on exit.
```

## 6. Commands

```bash
cargo build
cargo test
cargo clippy --all-targets
```

## 7. Related

| Path | Covers |
| :--- | :--- |
| `../CLAUDE.md` | Platform logging conventions (`tracing`, structured JSON, `#[instrument]`) |
| Consuming services | aggregator-bridge, trading-service, iam-service, noti-service, chain-bridge |
