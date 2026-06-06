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
    (cd gridtokenx-noti-service; cargo check)
    (cd gridtokenx-blockchain-core; cargo check)

# Build all binaries
build-all:
    (cd gridtokenx-iam-service; cargo build)
    (cd gridtokenx-trading-service; cargo build)
    (cd gridtokenx-oracle-bridge; cargo build)
    (cd gridtokenx-chain-bridge; cargo build)
    (cd gridtokenx-noti-service; cargo build)

# Build all binaries in release mode
build-release:
    (cd gridtokenx-iam-service; cargo build --release)
    (cd gridtokenx-trading-service; cargo build --release)
    (cd gridtokenx-oracle-bridge; cargo build --release)
    (cd gridtokenx-chain-bridge; cargo build --release)
    (cd gridtokenx-noti-service; cargo build --release)

# Run all microservice tests
test:
    (cd gridtokenx-iam-service; cargo test)
    (cd gridtokenx-trading-service; cargo test)
    (cd gridtokenx-oracle-bridge; cargo test)
    (cd gridtokenx-chain-bridge; cargo test)
    (cd gridtokenx-noti-service; cargo test)
    (cd gridtokenx-blockchain-core; cargo test)

# Run all tests including integration tests requiring solana validator
test-all:
    ./scripts/run_integration_tests.sh

# Run Edge Protocol integration test
test-edge:
    chmod +x scripts/test_edge_protocol.sh
    ./scripts/test_edge_protocol.sh

# Run User Registration & Onboarding E2E test
test-registration:
    chmod +x scripts/test-registration-e2e.sh
    ./scripts/test-registration-e2e.sh

# Run full E2E suite (health gate -> all suites). SKIP_GATE=1 to bypass app.sh doctor.
e2e:
    chmod +x tests/e2e/run.sh
    bash tests/e2e/run.sh

# Run a single E2E suite by name fragment, e.g. just e2e-suite name="10_iam"
e2e-suite name="00_harness":
    chmod +x tests/e2e/run.sh
    bash tests/e2e/run.sh {{name}}

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

# Revert last Notification migration
noti-migrate-revert:
    (cd gridtokenx-noti-service; sqlx migrate revert)

# Check database migration status (Notification)
noti-migrate-info:
    (cd gridtokenx-noti-service; sqlx migrate info)

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

# Rebuild all OrbStack services from scratch
orb-rebuild:
    docker compose build --no-cache
    docker compose up -d --force-recreate

# Clean all build artifacts
clean-all:
    (cd gridtokenx-iam-service; cargo clean)
    (cd gridtokenx-trading-service; cargo clean)
    (cd gridtokenx-oracle-bridge; cargo clean)
    (cd gridtokenx-chain-bridge; cargo clean)
    (cd gridtokenx-noti-service; cargo clean)
    (cd gridtokenx-blockchain-core; cargo clean)
    rm -rf target
    rm -rf scripts/logs

# Format all code
fmt:
    (cd gridtokenx-iam-service; cargo fmt)
    (cd gridtokenx-trading-service; cargo fmt)
    (cd gridtokenx-oracle-bridge; cargo fmt)
    (cd gridtokenx-chain-bridge; cargo fmt)
    (cd gridtokenx-noti-service; cargo fmt)
    (cd gridtokenx-blockchain-core; cargo fmt)

# Run clippy lints on all services
clippy:
    (cd gridtokenx-iam-service; cargo clippy -- -D warnings)
    (cd gridtokenx-trading-service; cargo clippy -- -D warnings)
    (cd gridtokenx-oracle-bridge; cargo clippy -- -D warnings)
    (cd gridtokenx-chain-bridge; cargo clippy -- -D warnings)
    (cd gridtokenx-noti-service; cargo clippy -- -D warnings)
    (cd gridtokenx-blockchain-core; cargo clippy -- -D warnings)

# Check database migration status (IAM)
migrate-info:
    (cd gridtokenx-iam-service; sqlx migrate info)

# Run oracle-bridge locally
run-oracle:
    (cd gridtokenx-oracle-bridge; cargo run)

# Run trading engine performance benchmarks (Criterion)
benchmark:
    (cd gridtokenx-trading-service/crates/trading-engine; cargo bench --bench matching_benchmark)

# --- Solana Localnet ---

# Start local solana test validator
solana-up:
    ./scripts/app.sh solana start

# Stop local solana test validator
solana-down:
    ./scripts/app.sh solana stop

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

# --- Smart Meter Automation ---

# Auto-send smartmeter data to oracle-bridge with blockchain linking
auto-meter-send meters="5" interval="15":
    gridtokenx-smartmeter-simulator/backend/.venv/bin/python scripts/auto-send-smartmeter-to-oracle.py --meters {{meters}} --interval {{interval}}

# Send single smartmeter reading to oracle-bridge
send-meter-reading meter_id="METER-001" count="1":
    gridtokenx-smartmeter-simulator/backend/.venv/bin/python scripts/send-smartmeter-to-oracle.py --meter-id {{meter_id}} --count {{count}}




