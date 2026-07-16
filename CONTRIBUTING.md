# Contributing to GridTokenX

> Last reviewed: 2026-07-17

Thank you for your interest in contributing to GridTokenX. This guide covers environment setup, the contribution workflow, and the conventions the repo enforces.

---

## Before Anything Else: This Is a Superproject

Every `gridtokenx-*` service is a **git submodule** with its own independent Cargo workspace — there is **no root `Cargo.toml`**.

- Clone with `--recursive`; after switching branches run `git submodule update --init --recursive`.
- **Never run `cargo` from the repo root** — `cd` into the service first.
- **Submodules are not all on `main`.** Check `git submodule status` before assuming; commit work on the submodule's current branch.
- **Two-step commit for submodule changes:** commit inside the submodule first, then commit the updated pointer in the superproject. A `git status` showing modified submodule pointers is normal.
- Docs live next to code — a submodule's `ARCHITECTURE.md` is committed in the submodule, then the pointer is bumped here.

---

## Prerequisites

| Tool | Version | Purpose |
|:---|:---|:---|
| **Rust** | Stable (latest) | Backend services |
| **OrbStack** | Latest | Docker runtime (macOS — not Docker Desktop) |
| **Solana CLI** | 1.18+ | Blockchain interaction |
| **Anchor CLI** | 1.0.0 | Smart contract framework |
| **Nushell** | Latest | Shell for `just` recipes and `grx.nu` |
| **just** | Latest | Task runner |
| **sqlx-cli** | Latest | Database migrations |
| **Node.js** | 20+ | Frontend applications |
| **Python** | 3.11+ | Smart Meter Simulator, doc-lint |

### Install Core Tools

```bash
# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# just (task runner)
cargo install just

# sqlx-cli
cargo install sqlx-cli --features postgres

# Nushell
brew install nushell

# OrbStack (Docker runtime for macOS)
brew install orbstack

# Solana CLI
sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"

# Anchor CLI
cargo install --git https://github.com/coral-xyz/anchor --tag v1.0.0 anchor-cli
```

---

## First-Time Setup

```bash
# 1. Clone with submodules
git clone --recursive https://github.com/gridtokenx/platform.git
cd platform

# 2. Configure environment
cp .env.example .env
# Review and adjust .env as needed

# 3. Generate dev mTLS certs (Chain Bridge CA + server + per-service client certs)
just gen-certs

# 4. Start infrastructure (PostgreSQL, Redis, Kafka, NATS, Vault, APISIX, ...)
./scripts/app.sh start --docker-only

# 5. Run database migrations
just migrate        # IAM Service
just noti-migrate   # Notification Service (separate DB, own migrations)

# 6. Initialize Solana blockchain and deploy programs
./scripts/app.sh init

# 7. Register admin user
./scripts/app.sh register

# 8. Verify everything works
./scripts/app.sh doctor
just check-all
```

---

## Development Workflow

### Running Services

```bash
# Option A: All services as native apps (recommended)
./scripts/app.sh start --native-apps

# Option B: Individual service (for focused development)
cd gridtokenx-iam-service && cargo run

# Option C: All in Docker
./scripts/app.sh start
```

### Making Changes

1. **Create a feature branch** — in the submodule you're changing, from its current tracking branch (not necessarily `main`).
2. **Identify which service** your change belongs to — see [ARCHITECTURE.md](ARCHITECTURE.md) §8 for the component index.
3. **Make your changes** following the code conventions in [CLAUDE.md](CLAUDE.md).
4. **Run checks in the service you changed** (never from repo root):
   ```bash
   cargo check
   cargo test
   cargo clippy -- -D warnings
   cargo fmt --check
   ```
5. **Update migrations** if you changed the schema:
   ```bash
   just migrate-new name:add_column_foo
   # Edit the generated migration SQL
   just migrate
   cargo sqlx prepare  # Update offline query data — commit the result
   ```
6. **Update the doc next to the code** — if the change affects a documented behavior, edit that component's `ARCHITECTURE.md`, then run the doc-lint gate:
   ```bash
   just lint-docs   # CI-enforced: fails on broken links + stale path:line citations
   ```
7. **Commit in the submodule, then bump the pointer** in the superproject.
8. **Submit a PR** with a clear description of what changed and why.

### Test First, Then Report

The repo's working rule (see [CLAUDE.md](CLAUDE.md)): after every code change, run the narrowest tests covering it **before** claiming done, and report the real pass/fail output. If tests can't run (missing infra, validator), say so explicitly — never claim success without evidence.

---

## Code Style

### Rust

- **Formatter**: `cargo fmt` (default `rustfmt` settings).
- **Linter**: `cargo clippy -- -D warnings` — all warnings treated as errors.
- **Error handling**: `anyhow::Result` for application logic, `thiserror` for typed API errors. Never `.unwrap()` in production paths.
- **Logging**: `tracing` crate with structured JSON output; `#[instrument(skip(...))]` on public async fns — never log secrets.
- **Async**: Tokio runtime. Never block in async contexts (`spawn_blocking` for CPU-heavy work).
- **Database**: SQLx with compile-time query verification.

### Architecture Patterns

- **Modular monolith** for complex services (IAM pioneered this — 6 sub-crates).
- **Layered architecture** for simpler services (api/core/domain/infra/services).
- **Dependency direction**: `server → api → logic → persistence → core` (never reverse).
- **Trait-based DI**: Define traits in `core`, implement in `persistence`, wire in `server`.
- **"Sync Core, Async Edges"**: Core business logic is sync; only edges (HTTP, DB, messaging) are async.
- **Blockchain only via Chain Bridge**: no service calls Solana RPC directly — writes over NATS JetStream, reads over gRPC.

### Naming Conventions

| What | Convention | Example |
|:---|:---|:---|
| Crate names | `kebab-case` | `iam-core`, `iam-logic` |
| Module names | `snake_case` | `auth_service.rs`, `user_repo.rs` |
| Struct names | `PascalCase` | `AuthService`, `UserRepository` |
| Trait names | `PascalCase` | `UserRepository`, `BlockchainProvider` |
| Function names | `snake_case` | `register_user`, `find_by_id` |
| Constants | `SCREAMING_SNAKE_CASE` | `MAX_RETRIES`, `DEFAULT_TIMEOUT` |
| Env variables | `SCREAMING_SNAKE_CASE` | `IAM_HTTP_PORT`, `DATABASE_URL` |

---

## Database Migrations

Migrations are managed via SQLx and live in `<service>/migrations/`.

```bash
# IAM Service
just migrate           # Apply all pending migrations
just migrate-new name:add_foo  # Create new migration
just migrate-revert    # Revert last migration
just migrate-info      # Show migration status

# Notification Service — SEPARATE database, separate recipes
just noti-migrate
just noti-migrate-revert
just noti-migrate-info

# After changing queries, update offline data
cd gridtokenx-iam-service && cargo sqlx prepare
```

### Migration Best Practices

- Migrations are **append-only** — never edit an existing migration file.
- Each migration should be **reversible** (include both up and down SQL).
- Use **descriptive names**: `20260416_add_user_wallet_address.sql`, not `change.sql`.
- Test migrations against a fresh database before committing.
- The platform is mid-way through a **database-per-service split** — check
  [docs/design-docs/db-per-service-migration.md](docs/design-docs/db-per-service-migration.md)
  before adding cross-service SQL (JOINs to another service's tables are being removed, not added).

---

## Testing

### Test Hierarchy

1. **Unit tests** (`cargo test`): Every function with meaningful logic should have unit tests.
2. **Integration tests** (`tests/` directory): Test service boundaries, DB operations, API endpoints.
3. **Anchor program tests** (`anchor test`): On-chain program behavior.
4. **Cross-service E2E** (`just e2e`, `tests/e2e/`): Full pipeline validation — needs infra up.
5. **Load tests / benchmarks** (`just benchmark`, `just bench-ingest`): Performance suites.

### Running Tests

```bash
# Unit tests (fast, no infra needed) — always from inside the service
cd gridtokenx-iam-service && cargo test
cd gridtokenx-iam-service && cargo test -p iam-logic   # scope to one crate

# All services
just test

# Integration + E2E (require Docker services)
just orb-up
just test-all           # includes Solana validator suites
just e2e                # full cross-service flow
just test-registration  # IAM registration E2E (register→verify→on-chain PDA)
just test-edge          # Edge/DLMS protocol against the Aggregator Bridge
just openadr-e2e        # OpenADR VTN↔VEN demand-response flow

# Anchor program tests
cd gridtokenx-anchor && anchor test

# Benchmarks
just benchmark
```

Frontend submodules (`gridtokenx-trading`, `gridtokenx-explorer`) use their own `npm test` / `npm run build` — not `cargo`.

---

## PR Checklist

Before submitting a PR, ensure:

- [ ] `cargo check` passes (in the changed service)
- [ ] `cargo test` passes (relevant service) — real output, not assumed
- [ ] `cargo clippy -- -D warnings` passes
- [ ] `cargo fmt --check` passes
- [ ] New migrations have `cargo sqlx prepare` committed
- [ ] `just lint-docs` passes if docs changed
- [ ] Documentation updated if public API or documented behavior changed
- [ ] Submodule commit landed first; superproject bumps the pointer
- [ ] No secrets or private keys in the diff

---

## Need Help?

- **Architecture questions**: See [ARCHITECTURE.md](ARCHITECTURE.md)
- **Coding conventions**: See [CLAUDE.md](CLAUDE.md)
- **Domain terms**: See [docs/glossary.md](docs/glossary.md)
- **Dev workflows**: See [.agents/workflows/](.agents/workflows/)
- **Service deep dives**: See each service's `ARCHITECTURE.md` (indexed in [ARCHITECTURE.md](ARCHITECTURE.md) §8)
