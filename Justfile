# GridTokenX Justfile - Development Commands

set shell := ["nu", "-c"]

# Default command - show help
default:
    @echo "Available commands:"
    @echo "  just check-all          - Run cargo check on all microservices"
    @echo "  just build-all          - Build all microservice binaries"
    @echo "  just test               - Run all tests"
    @echo "  just migrate            - Run sqlx migrations (IAM)"
    @echo "  just db-up              - Start PostgreSQL container (OrbStack)"
    @echo "  just db-down            - Stop PostgreSQL container"
    @echo "  just orb-up             - Start all OrbStack services"
    @echo "  just orb-down           - Stop all OrbStack services"
    @echo "  just fmt                - Format all code"
    @echo "  just clippy             - Run clippy lints on all services"

# Check all codebases
check-all:
    (cd gridtokenx-iam-service; cargo check)
    (cd gridtokenx-trading-service; cargo check)
    (cd gridtokenx-oracle-bridge; cargo check)
    (cd gridtokenx-chain-bridge; cargo check)
    (cd gridtokenx-edge-gateway; cargo check)
    (cd gridtokenx-noti-service; cargo check)

# Build all binaries
build-all:
    (cd gridtokenx-iam-service; cargo build)
    (cd gridtokenx-trading-service; cargo build)
    (cd gridtokenx-oracle-bridge; cargo build)
    (cd gridtokenx-chain-bridge; cargo build)
    (cd gridtokenx-edge-gateway; cargo build)
    (cd gridtokenx-noti-service; cargo build)

# Run all microservice tests
test:
    (cd gridtokenx-iam-service; cargo test)
    (cd gridtokenx-trading-service; cargo test)
    (cd gridtokenx-oracle-bridge; cargo test)
    (cd gridtokenx-chain-bridge; cargo test)
    (cd gridtokenx-noti-service; cargo test)

# Run all tests including integration tests requiring solana validator
test-all:
    ./scripts/run_integration_tests.sh

# Run Edge Protocol integration test
test-edge:
    chmod +x scripts/test_edge_protocol.sh
    ./scripts/test_edge_protocol.sh

# Run migrations (IAM Service)
migrate:
    (cd gridtokenx-iam-service; sqlx migrate run)

# Create a new IAM migration
migrate-new name:
    (cd gridtokenx-iam-service; sqlx migrate add {{name}})

# Revert last IAM migration
migrate-revert:
    (cd gridtokenx-iam-service; sqlx migrate revert)

# Run migrations (Notification Service)
noti-migrate:
    (cd gridtokenx-noti-service; sqlx migrate run)

# Create a new Notification migration
noti-migrate-new name:
    (cd gridtokenx-noti-service; sqlx migrate add {{name}})

# Start PostgreSQL (OrbStack)
db-up:
    docker compose up -d postgres

# Stop PostgreSQL
db-down:
    docker compose down postgres

# Start all OrbStack services
orb-up:
    docker compose up -d

# Stop all OrbStack services
orb-down:
    docker compose down

# Clean all build artifacts
clean-all:
    cargo clean
    rm -rf target
    rm -rf scripts/logs

# Format all code
fmt:
    cargo fmt

# Run clippy lints on all services
clippy:
    (cd gridtokenx-iam-service; cargo clippy -- -D warnings)
    (cd gridtokenx-trading-service; cargo clippy -- -D warnings)
    (cd gridtokenx-oracle-bridge; cargo clippy -- -D warnings)
    (cd gridtokenx-chain-bridge; cargo clippy -- -D warnings)
    (cd gridtokenx-noti-service; cargo clippy -- -D warnings)

# Check database migration status (IAM)
migrate-info:
    (cd gridtokenx-iam-service; sqlx migrate info)

# Run oracle-bridge locally
run-oracle:
    (cd gridtokenx-oracle-bridge; cargo run)

# Run trading engine performance benchmarks
benchmark:
    (cd gridtokenx-trading-service; cargo test --test trading_engine_bench -- --nocapture)

# --- Solana Mainnet Simulation (Surfpool) ---

# Start mainnet simulation with Studio and hot-reload
simnet:
    NO_DNA=1 surfpool start --network mainnet --watch

# Start mainnet simulation in CI mode (no UI, fast startup)
simnet-ci:
    NO_DNA=1 surfpool start --network mainnet --ci

# Stop any running Surfpool instances
simnet-down:
    pkill -f surfpool || true

# --- OrbStack rebuild (All Services) ---




