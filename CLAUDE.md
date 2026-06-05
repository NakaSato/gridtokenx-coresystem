# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Also auto-read by other LLM coding assistants.
> Last reviewed: 2026-06-05

---

## Quick Orientation

- This repo is a **superproject**: every `gridtokenx-*` service is a **git submodule** (see `.gitmodules`). After clone or branch switch run `git submodule update --init --recursive`. A `git status` showing modified submodule pointers is normal — commit the pointer in the superproject, the code inside the submodule.
- Read [README.md](README.md) for the full architecture diagram, service list, and port table. No root `ARCHITECTURE.md` exists; per-service detail lives in `<service>/ARCHITECTURE.md` (IAM and Noti have one).
- Read [docs/glossary.md](docs/glossary.md) for domain terms (GRID, GRX, REC, VPP, CDA, PDA, etc.).
- Each service = **independent Cargo workspace** — no root `Cargo.toml`. Don't `cargo` from repo root; `cd` into the service first.
- IAM Service = **modular monolith** with 6 sub-crates. Others: layered modules, single crate.
- Two interconnected platforms: **Exchange** (IAM + Trading, direct blockchain) and **Infrastructure** (Oracle Bridge + edge, produces validated telemetry). Gateways: **APISIX** (`:4001`, user-facing) and **Envoy** (`:4002`, IoT/mTLS edge); **API orchestrator** at `:4000`.

---

## Build & Test Commands

### Per-Service (most common)

```bash
# Check a single service (fast feedback)
cd gridtokenx-iam-service && cargo check
cd gridtokenx-trading-service && cargo check
cd gridtokenx-oracle-bridge && cargo check
cd gridtokenx-chain-bridge && cargo check

# Run tests for a single service
cd gridtokenx-iam-service && cargo test
cd gridtokenx-trading-service && cargo test
```

### Workspace-Wide (via just — requires Nushell)

```bash
just check-all          # cargo check all microservices
just build-all          # cargo build all microservices
just build-release      # cargo build all microservices in release mode
just test               # cargo test all microservices
just fmt                # cargo fmt
just clippy             # cargo clippy -- -D warnings (all services)
just clean-all          # Remove all build artifacts
```

### Database

```bash
just db-up              # Start PostgreSQL container
just db-down            # Stop PostgreSQL container
just migrate            # Run sqlx migrations (IAM Service)
just migrate-new name:X # Create new migration
just migrate-revert     # Revert last migration
just migrate-info       # Show migration status
```

### Docker / Infrastructure

```bash
just orb-up             # Start all Docker services (OrbStack)
just orb-down           # Stop all Docker services
just orb-rebuild        # Rebuild all services (no cache)
./scripts/app.sh start --docker-only   # Start infrastructure only
./scripts/app.sh stop                  # Stop everything
./scripts/app.sh status                # Process status
./scripts/app.sh doctor                # Health check
```

`scripts/app.sh` is the unified orchestrator (subcommands: `start`, `stop`, `restart`, `status`, `doctor`, `init`, `logs`, `solana`).

### Blockchain

```bash
./scripts/app.sh init                  # Initialize Solana + deploy programs
just solana-up                         # Start local solana-test-validator
just solana-down                       # Stop validator
cd gridtokenx-anchor && anchor build   # Build Anchor programs
cd gridtokenx-anchor && anchor test    # Run Anchor integration tests
just test-all                          # All tests including Solana validator

# Mainnet simulation (Surfpool) — no local validator needed
just simnet                            # Mainnet sim with Studio + hot-reload
just simnet-ci                         # CI mode (no UI, fast startup)
just simnet-down                       # Kill running Surfpool

# Smart-meter telemetry into Oracle Bridge
just auto-meter-send meters="5" interval="15"
just send-meter-reading meter_id="METER-001" count="1"
```

> **macOS Apple Silicon Warning**: Running `solana-test-validator` natively on M-series chips will panic with a "Too many open files" error under load. The `app.sh` scripts handle this automatically via `ulimit -n 65536`. If you run the validator manually outside these scripts, you MUST tune the system limits first.

---

## Architecture Rules

### "Sync Core, Async Edges"

IAM follows this; other services adopt it:

- **Core** (business logic): **synchronous traits** — pure functions, no async, no framework deps.
- **Edges** (API handlers, persistence, message consumers): **async** — bridge sync core to async world.
- Makes core easy to unit test without mocking async runtimes.

### Dependency Direction

```
server → api → logic → persistence → core
```

Never reverse. Business logic never imports HTTP types. Handlers never import SQL queries.

### Trait-Based Dependency Injection

Define traits in `core` (or `domain/`), implement in `persistence` (or `infra/`), wire in `server` (or `startup/`).

```rust
// In core/traits.rs — define the contract
pub trait UserRepository {
    fn find_by_id(&self, id: &Uuid) -> Result<User>;
}

// In persistence/user_repo.rs — implement it
pub struct PgUserRepository { pool: PgPool }
impl UserRepository for PgUserRepository { ... }

// In server/startup.rs — wire it
let repo = PgUserRepository::new(pool);
let service = AuthService::new(Arc::new(repo));
```

### Blockchain Access

**All Solana transactions go through Chain Bridge.** No service calls Solana RPC directly.

- **Writes**: Publish to NATS JetStream (`chain.tx.submit`, `chain.tx.simulate`)
- **Reads**: gRPC call to Chain Bridge (balance, account data, slot)
- **Shared types**: `gridtokenx-blockchain-core` crate

---

## Code Conventions

### Error Handling

```rust
// Use anyhow::Result for application-level errors
use anyhow::{Result, Context};

pub fn process_order(order: &Order) -> Result<Trade> {
    let market = find_market(order.market_id)
        .context("Failed to find market for order")?;
    // ...
}
```

- Use `anyhow::Result` for fallible ops in service logic.
- Use `thiserror` for typed errors at API boundaries where clients need structured error codes.
- **Never `.unwrap()` in production.** Use `.context()` or `.expect("reason")` with meaningful message only in init code where failure is fatal.

### Logging

```rust
use tracing::{info, warn, error, debug, instrument};

#[instrument(skip(pool), fields(user_id = %user_id))]
pub async fn register_user(pool: &PgPool, user_id: Uuid) -> Result<User> {
    info!("Starting user registration");
    // ...
}
```

- Use `tracing` (not `log`). All services use structured JSON logging.
- `#[instrument]` on public async functions. `skip` to avoid logging sensitive data (passwords, keys, tokens).
- Log levels: `error` = actionable failures, `warn` = degraded but functional, `info` = business events, `debug` = dev-only.

### Axum Handlers

```rust
// Handlers extract typed state, return impl IntoResponse
pub async fn create_order(
    State(state): State<AppState>,
    Json(req): Json<CreateOrderRequest>,
) -> Result<Json<OrderResponse>, AppError> {
    let order = state.trading_service.create_order(req).await?;
    Ok(Json(OrderResponse::from(order)))
}
```

- Handlers thin — validate input, call service, return response.
- Business logic in service layer, never in handlers.
- `State(state)` for DI, not global statics.

### Database (SQLx)

```rust
// Use compile-time checked queries
let user = sqlx::query_as!(
    User,
    r#"SELECT id, email, role as "role: UserRole" FROM users WHERE id = $1"#,
    user_id
)
.fetch_optional(&pool)
.await?;
```

- `sqlx::query_as!` for compile-time verified queries.
- Run `cargo sqlx prepare` before committing if queries change (offline mode).
- Migrations in `<service>/migrations/`, use `sqlx migrate`.
- Connection URL: `DATABASE_URL` env var (default: `postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx`).

### Protobuf / ConnectRPC

- Proto files in `<service>/crates/<service>-protocol/proto/` (IAM) or `<service>/proto/` (others).
- Use `prost` + `tonic` for codegen.
- gRPC services use ConnectRPC (HTTP/2 compatible, browser-friendly).

---

## What to Avoid

1. **Direct DB calls from handlers.** Always through service/repository layer.
2. **Blocking in async code.** Use `tokio::task::spawn_blocking` for CPU-heavy work.
3. **Hardcoded port numbers.** Read from env vars (`IAM_HTTP_PORT`, `TRADING_GRPC_PORT`, etc.).
4. **Logging secrets.** Never log passwords, private keys, JWT tokens, encryption keys. Use `#[instrument(skip(password))]`.
5. **Direct Solana RPC calls from services.** All blockchain interaction through Chain Bridge.
6. **`cargo add` in wrong service workspace.** Each service has own `Cargo.toml`; don't add deps to wrong workspace.
7. **`.unwrap()` in production paths.** Use `?` with context. Reserve `.unwrap()` for truly impossible cases with `// SAFETY: ...` comment.

---

## Testing

### Unit Tests

```bash
# Run tests for a specific crate within IAM
cd gridtokenx-iam-service && cargo test -p iam-logic

# Run a specific test
cd gridtokenx-trading-service && cargo test test_order_matching -- --nocapture
```

### Integration Tests (require infrastructure)

```bash
# Start infrastructure first
just orb-up

# Run integration tests
just test-all

# Anchor program tests (require Solana validator)
cd gridtokenx-anchor && anchor test

# Trading engine benchmarks
just benchmark
```

### Test Conventions

- Unit tests in `#[cfg(test)] mod tests` at bottom of each file.
- Integration tests in `tests/` dir of each service.
- Use real DB connections for integration tests (not mocks) via test containers or dev Postgres.
- Anchor program tests use Bankrun test framework.

---

## Environment

- Copy `.env.example` to `.env` for dev defaults.
- Port numbering: 4000s=gateways, 5000s=gRPC mesh, 7000s=persistence, 9000s=messaging.
- See the port table in [README.md](README.md) for the full scheme.
- Docker runtime: **OrbStack** (not Docker Desktop) for macOS.
- Shell: Nushell required for `just` and `grx.nu` scripts.

---

## Service-Specific Gotchas

### IAM Service
- Modular monolith with 6 sub-crates. New feature → pick crate per dependency direction rule.
- Wallet keys encrypted with AES-256-GCM. `ENCRYPTION_SECRET` must be 32+ chars.
- On-chain registration creates PDA via Registry program — idempotent but needs Solana validator running.

### Trading Service
- Own Cargo workspace (excluded from root due to BPF target conflicts).
- Matching engine in `src/domain/` — CDA (Continuous Double Auction) algorithm.
- Settlement through Chain Bridge, not direct Solana RPC.
- `src/startup/` has `ServiceBuilder` pattern for wiring deps.

### Oracle Bridge
- Validates Ed25519 signatures from Edge Gateways. Device identity verified cryptographically.
- 15-minute aggregation windows for energy data before settlement.
- InfluxDB for time-series storage (not Postgres).
- Disseminates verified readings to Redis Streams and Kafka.

### Chain Bridge
- **Only** service that directly touches Solana RPC.
- Signs transactions using Vault Transit (not local keypair files — dev mode supports keypair path).
- NATS JetStream for async tx submission; gRPC for synchronous reads.
- Binds to `127.0.0.1` only (never `0.0.0.0`).