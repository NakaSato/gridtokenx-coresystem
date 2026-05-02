# Contributing to GridTokenX

> Last reviewed: 2026-04-16

Thank you for your interest in contributing to GridTokenX. This guide will help you set up your development environment and understand our contribution workflow.

---

## Prerequisites

| Tool | Version | Purpose |
|:---|:---|:---|
| **Rust** | Stable (latest) | Backend services |
| **OrbStack** | Latest | Docker runtime (macOS) |
| **Solana CLI** | 1.18+ | Blockchain interaction |
| **Anchor CLI** | 1.0.0 | Smart contract framework |
| **Nushell** | Latest | Shell for `just` and `grx.nu` scripts |
| **just** | Latest | Task runner |
| **sqlx-cli** | Latest | Database migrations |
| **Node.js** | 20+ | Frontend applications |
| **Python** | 3.11+ | Smart Meter Simulator |

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

# 3. Start infrastructure (PostgreSQL, Redis, Kafka, etc.)
./scripts/app.sh start --docker-only

# 4. Run database migrations
just migrate

# 5. Initialize Solana blockchain and deploy programs
./scripts/app.sh init

# 6. Register admin user
./scripts/app.sh register

# 7. Verify everything works
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

1. **Create a feature branch** from `main`.
2. **Identify which service** your change belongs to — see [ARCHITECTURE.md](ARCHITECTURE.md) for the crate inventory.
3. **Make your changes** following the code conventions in [CLAUDE.md](CLAUDE.md).
4. **Run checks** before committing:
   ```bash
   # In the service you changed
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
   cargo sqlx prepare  # Update offline query data
   ```
6. **Submit a PR** with a clear description of what changed and why.

---

## Code Style

### Rust

- **Formatter**: `cargo fmt` (default `rustfmt` settings).
- **Linter**: `cargo clippy -- -D warnings` — all warnings treated as errors.
- **Error handling**: `anyhow::Result` for application logic, `thiserror` for typed API errors.
- **Logging**: `tracing` crate with structured JSON output.
- **Async**: Tokio runtime. Never block in async contexts.
- **Database**: SQLx with compile-time query verification.

### Architecture Patterns

- **Modular monolith** for complex services (IAM pioneered this — 6 sub-crates).
- **Layered architecture** for simpler services (api/core/domain/infra/services).
- **Dependency direction**: `server → api → logic → persistence → core` (never reverse).
- **Trait-based DI**: Define traits in `core`, implement in `persistence`, wire in `server`.
- **"Sync Core, Async Edges"**: Core business logic is sync; only edges (HTTP, DB, messaging) are async.

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

# After changing queries, update offline data
cd gridtokenx-iam-service && cargo sqlx prepare
```

### Migration Best Practices

- Migrations are **append-only** — never edit an existing migration file.
- Each migration should be **reversible** (include both up and down SQL).
- Use **descriptive names**: `20260416_add_user_wallet_address.sql`, not `change.sql`.
- Test migrations against a fresh database before committing.

---

## Testing

### Test Hierarchy

1. **Unit tests** (`cargo test`): Every function with meaningful logic should have unit tests.
2. **Integration tests** (`tests/` directory): Test service boundaries, DB operations, API endpoints.
3. **Anchor program tests** (`anchor test`): On-chain program behavior with Bankrun.
4. **End-to-end tests** (`just test-all`): Full pipeline validation requiring Solana validator.
5. **Load tests** (`tests/load-test/`): Performance benchmarks.

### Running Tests

```bash
# Unit tests (fast, no infra needed)
cd gridtokenx-iam-service && cargo test

# All services
just test

# Integration tests (require Docker services)
just orb-up && just test-all

# Anchor program tests
cd gridtokenx-anchor && anchor test

# Benchmarks
just benchmark
```

---

## PR Checklist

Before submitting a PR, ensure:

- [ ] `cargo check` passes
- [ ] `cargo test` passes (relevant service)
- [ ] `cargo clippy -- -D warnings` passes
- [ ] `cargo fmt --check` passes
- [ ] New migrations have `cargo sqlx prepare` committed
- [ ] Documentation updated if public API changed
- [ ] No secrets or private keys in the diff

---

## Need Help?

- **Architecture questions**: See [ARCHITECTURE.md](ARCHITECTURE.md)
- **Coding conventions**: See [CLAUDE.md](CLAUDE.md)
- **Domain terms**: See [docs/glossary.md](docs/glossary.md)
- **Dev workflows**: See [.agent/workflows/](.agent/workflows/)
- **Service deep dives**: See each service's `README.md` or [ARCHITECTURE.md](ARCHITECTURE.md)
