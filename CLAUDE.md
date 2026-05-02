# CLAUDE.md — LLM Coding Conventions for GridTokenX

> This file is read automatically by Claude Code and other LLM coding assistants.
> Last reviewed: 2026-04-16

---

## Quick Orientation

- Read [ARCHITECTURE.md](ARCHITECTURE.md) first — it has the full crate inventory, dependency rules, and layer diagram.
- Read [docs/glossary.md](docs/glossary.md) for domain terms (GRID, GRX, REC, VPP, CDA, PDA, etc.).
- Each service is an **independent Cargo workspace** — there is no root `Cargo.toml`.
- The IAM Service uses a **modular monolith** with 6 sub-crates. Other services use layered modules within a single crate.

---

## Build & Test Commands

### Per-Service (most common)

```bash
# Check a single service (fast feedback)
cd gridtokenx-iam-service && cargo check
cd gridtokenx-trading-service && cargo check
cd gridtokenx-oracle-bridge && cargo check
cd gridtokenx-chain-bridge && cargo check
cd gridtokenx-agent-trade && cargo check

# Run tests for a single service
cd gridtokenx-iam-service && cargo test
cd gridtokenx-trading-service && cargo test
```

### Workspace-Wide (via just — requires Nushell)

```bash
just check-all          # cargo check all microservices
just build-all          # cargo build all microservices
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
./scripts/app.sh start --native-apps   # Docker + native services
./scripts/app.sh stop                  # Stop everything
./scripts/app.sh doctor                # Health check
```

### Blockchain

```bash
./scripts/app.sh init                  # Initialize Solana + deploy programs
cd gridtokenx-anchor && anchor build   # Build Anchor programs
cd gridtokenx-anchor && anchor test    # Run Anchor integration tests
just test-all                          # All tests including Solana validator
```

---

## Architecture Rules

### "Sync Core, Async Edges"

The IAM service follows this pattern and other services should adopt it:

- **Core** (business logic) uses **synchronous traits** — pure functions, no async, no framework deps.
- **Edges** (API handlers, persistence, message consumers) are **async** — they bridge the sync core to the async world.
- This makes core logic easy to unit test without mocking async runtimes.

### Dependency Direction

```
server → api → logic → persistence → core
```

Never the reverse. Business logic never imports HTTP types. Handlers never import SQL queries.

### Trait-Based Dependency Injection

Services define traits in `core` (or `domain/`), implement them in `persistence` (or `infra/`), and wire them together in `server` (or `startup/`).

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

- Use `anyhow::Result` for fallible operations in service logic.
- Use `thiserror` for typed errors at API boundaries where clients need structured error codes.
- **Never use `.unwrap()` in production code.** Use `.context()` or `.expect("reason")` with a meaningful message only in initialization code where failure is fatal.

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
- Use `#[instrument]` on public async functions. Use `skip` to avoid logging sensitive data (passwords, keys, tokens).
- Log levels: `error` = actionable failures, `warn` = degraded but functional, `info` = business events, `debug` = dev-only detail.

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

- Handlers are thin — validate input, call a service, return response.
- Business logic lives in service layer, never in handlers.
- Use `State(state)` for dependency injection, not global statics.

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

- Use `sqlx::query_as!` for compile-time verified queries.
- Run `cargo sqlx prepare` before committing if you change queries (offline mode).
- Migrations live in `<service>/migrations/` and use `sqlx migrate`.
- Connection URL: `DATABASE_URL` env var (default: `postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx`).

### Protobuf / ConnectRPC

- Proto files live in `<service>/crates/<service>-protocol/proto/` (IAM) or `<service>/proto/` (others).
- Use `prost` + `tonic` for code generation.
- gRPC services use ConnectRPC (HTTP/2 compatible, browser-friendly).

---

## What to Avoid

1. **Direct DB calls from handlers.** Always go through a service/repository layer.
2. **Blocking in async code.** Use `tokio::task::spawn_blocking` for CPU-heavy work.
3. **Hardcoded port numbers.** Read from env vars (`IAM_HTTP_PORT`, `TRADING_GRPC_PORT`, etc.).
4. **Logging secrets.** Never log passwords, private keys, JWT tokens, encryption keys. Use `#[instrument(skip(password))]`.
5. **Direct Solana RPC calls from services.** All blockchain interaction goes through Chain Bridge.
6. **cargo add in a different service's workspace.** Each service has its own `Cargo.toml`; don't accidentally add deps to the wrong workspace.
7. **`.unwrap()` in production paths.** Use `?` with context. Reserve `.unwrap()` for truly impossible cases with a `// SAFETY: ...` comment.

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

- Unit tests live in `#[cfg(test)] mod tests` at the bottom of each file.
- Integration tests live in `tests/` directory of each service.
- Use real database connections for integration tests (not mocks) via test containers or the dev Postgres.
- Anchor program tests use the Bankrun test framework.

---

## Environment

- Copy `.env.example` to `.env` for development defaults.
- Port numbering: 4000s=gateways, 5000s=gRPC mesh, 7000s=persistence, 9000s=messaging.
- See [ARCHITECTURE.md](ARCHITECTURE.md) for the full port scheme.
- Docker runtime: **OrbStack** (not Docker Desktop) for macOS.
- Shell: Nushell required for `just` and `grx.nu` scripts.

---

## Service-Specific Gotchas

### IAM Service
- Uses modular monolith with 6 sub-crates. When adding a new feature, decide which crate it belongs in based on the dependency direction rule.
- Wallet keys are encrypted with AES-256-GCM. The `ENCRYPTION_SECRET` env var must be 32+ characters.
- On-chain registration creates a PDA via the Registry program — this is idempotent but requires the Solana validator running.

### Trading Service
- Has its own Cargo workspace (excluded from root because of BPF target conflicts).
- The matching engine is in `src/domain/` — CDA (Continuous Double Auction) algorithm.
- Settlement goes through Chain Bridge, not direct Solana RPC.
- `src/startup/` contains the `ServiceBuilder` pattern for wiring dependencies.

### Oracle Bridge
- Validates Ed25519 signatures from Edge Gateways. The device identity is verified cryptographically.
- 15-minute aggregation windows for energy data before settlement.
- Uses InfluxDB for time-series storage (not Postgres).
- Has a NILM (Non-Intrusive Load Monitoring) module for appliance disaggregation.

### Chain Bridge
- The **only** service that directly touches Solana RPC.
- Signs transactions using Vault Transit (not local keypair files — though dev mode supports keypair path).
- NATS JetStream for async transaction submission; gRPC for synchronous reads.
- Binds to `127.0.0.1` only (never `0.0.0.0`).

### Agent Trade
- Algorithmic trading agent with an actor-based architecture (MarketData, Execution, Strategy, Risk).
- MarketData actor uses Binance WebSocket streams (trade + depth) with auto-reconnect.
- Uses `rust_decimal` for all financial calculations (never floats).
- Persistent state (order history) stored in SQLite via SQLx.
- Communicates with IAM and Trading services via gRPC.
