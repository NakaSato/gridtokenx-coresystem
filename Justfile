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
    @echo "  just verify-conns       - Probe Trading Service dependency connections"

# Check all codebases
check-all:
    (cd gridtokenx-iam-service; cargo check)
    (cd gridtokenx-trading-service; cargo check)
    (cd gridtokenx-aggregator-bridge; cargo check)
    (cd gridtokenx-chain-bridge; cargo check)
    (cd gridtokenx-noti-service; cargo check)
    (cd gridtokenx-blockchain-core; cargo check)

# Build all binaries
build-all:
    (cd gridtokenx-iam-service; cargo build)
    (cd gridtokenx-trading-service; cargo build)
    (cd gridtokenx-aggregator-bridge; cargo build)
    (cd gridtokenx-chain-bridge; cargo build)
    (cd gridtokenx-noti-service; cargo build)

# Build all binaries in release mode
build-release:
    (cd gridtokenx-iam-service; cargo build --release)
    (cd gridtokenx-trading-service; cargo build --release)
    (cd gridtokenx-aggregator-bridge; cargo build --release)
    (cd gridtokenx-chain-bridge; cargo build --release)
    (cd gridtokenx-noti-service; cargo build --release)

# Run all microservice tests
test:
    (cd gridtokenx-iam-service; cargo test)
    (cd gridtokenx-trading-service; cargo test)
    (cd gridtokenx-aggregator-bridge; cargo test)
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

# Generate dev mTLS CA + Chain Bridge server cert + per-SPIFFE-identity client certs into infra/certs/
gen-certs:
    chmod +x scripts/gen-certs.sh
    bash scripts/gen-certs.sh

# Lint docs harness: broken relative links + stale path:line citations
lint-docs:
    python3 scripts/lint-docs.py

# Lint docs across superproject + every checked-out submodule (validates
# code-anchored path:line claims against the tree where the file lives)
lint-docs-all:
    bash scripts/lint-docs-all.sh

# Advisory: list docs whose `Last reviewed:` date is older than days (default 180)
lint-docs-stale days="180":
    python3 scripts/lint-docs.py --warn-stale {{days}}

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

# System health check: deps, certs, APISIX upstream backends, trading connections
doctor:
    ./scripts/app.sh doctor

# Flag running service containers whose image predates its source (deploy drift)
check-drift:
    bash scripts/check-image-drift.sh

# Rebuild + recreate only the service containers that are stale vs their source
rebuild-stale:
    bash scripts/check-image-drift.sh --fix

# Clean all build artifacts
clean-all:
    (cd gridtokenx-iam-service; cargo clean)
    (cd gridtokenx-trading-service; cargo clean)
    (cd gridtokenx-aggregator-bridge; cargo clean)
    (cd gridtokenx-chain-bridge; cargo clean)
    (cd gridtokenx-noti-service; cargo clean)
    (cd gridtokenx-blockchain-core; cargo clean)
    rm -rf target
    rm -rf scripts/logs

# Format all code
fmt:
    (cd gridtokenx-iam-service; cargo fmt)
    (cd gridtokenx-trading-service; cargo fmt)
    (cd gridtokenx-aggregator-bridge; cargo fmt)
    (cd gridtokenx-chain-bridge; cargo fmt)
    (cd gridtokenx-noti-service; cargo fmt)
    (cd gridtokenx-blockchain-core; cargo fmt)

# Run clippy lints on all services
clippy:
    (cd gridtokenx-iam-service; cargo clippy -- -D warnings)
    (cd gridtokenx-trading-service; cargo clippy -- -D warnings)
    (cd gridtokenx-aggregator-bridge; cargo clippy -- -D warnings)
    (cd gridtokenx-chain-bridge; cargo clippy -- -D warnings)
    (cd gridtokenx-noti-service; cargo clippy -- -D warnings)
    (cd gridtokenx-blockchain-core; cargo clippy -- -D warnings)

# Check database migration status (IAM)
migrate-info:
    (cd gridtokenx-iam-service; sqlx migrate info)

# Run aggregator-bridge locally
run-oracle:
    (cd gridtokenx-aggregator-bridge; cargo run)

# Verify Trading Service can reach all its internal dependencies (Postgres, Redis, Chain Bridge gRPC, NATS, IAM, Kafka)
verify-conns:
    (cd gridtokenx-trading-service; cargo run --quiet --bin verify-connections)

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

# Stream signed smartmeter readings into the Aggregator Bridge (DLMS/COSEM egress).
# Needs the bridge IoT gateway (:4030) + Redis (:7010) up (`just orb-up`). Loops
# until Ctrl-C; each tick POSTs signed OBIS frames -> /v1/private-network/ingest.
auto-meter-send meters="5" interval="15":
    (cd gridtokenx-smartmeter-simulator/backend; with-env {AGGREGATOR_DLMS_ENABLED: "true", AGGREGATOR_BRIDGE_URL: "http://localhost:4030", REDIS_URL: "redis://localhost:7010"} { uv run python scripts/send_to_aggregator_bridge.py --meters {{meters}} --interval {{interval}} --onboard })

# Single-meter egress burst into the Aggregator Bridge (quick smoke test; Ctrl-C to stop).
send-meter-reading meters="1" interval="15":
    (cd gridtokenx-smartmeter-simulator/backend; with-env {AGGREGATOR_DLMS_ENABLED: "true", AGGREGATOR_BRIDGE_URL: "http://localhost:4030", REDIS_URL: "redis://localhost:7010"} { uv run python scripts/send_to_aggregator_bridge.py --meters {{meters}} --interval {{interval}} --onboard })

# OpenADR dispatch end-to-end test: telemetry -> frequency window -> Kafka ->
# dispatch engine -> event on the local VTN (BL) -> VEN listener executes it.
# Starts redis/kafka-cmd/openleadr-vtn via compose; briefly stops the
# aggregator-bridge container (restored on exit) to avoid consumer-group races.
openadr-e2e:
    bash scripts/openleadr-e2e.sh

# Run the full smart-meter SERVER (UI + GLM engine) with Aggregator Bridge egress ON.
# Sim egress is opt-in (AGGREGATOR_DLMS_ENABLED defaults false), so a plain
# `--mode server` launch streams NOTHING to the bridge. This recipe forces it on
# so the running app feeds the aggregator. Needs bridge (:4030) + Redis (:7010) up.
meter-server port="8082" interval="5":
    (cd gridtokenx-smartmeter-simulator/backend; with-env {AGGREGATOR_DLMS_ENABLED: "true", AGGREGATOR_BRIDGE_URL: "http://localhost:4030", REDIS_URL: "redis://localhost:7010"} { uv run python -m smart_meter_simulator.cli --mode server --port {{port}} --interval {{interval}} })





# Launch a Claude Code session in a new terminal at a project path, remembering
# the last-used path. No arg reopens the last session; pass path= to set it.
#   just session                       # reuse last session path
#   just session path="gridtokenx-iam-service"
session path="":
    bash scripts/session.sh {{path}}

# Print the saved last session path.
session-last:
    bash scripts/session.sh --last

# List known service names selectable by `just session path=<name>`.
session-list:
    bash scripts/session.sh --list

# Pick service(s) and launch a session each. Multi-select supported.
# Arg is POSITIONAL (just CLI args are positional, not name=value):
#   just session-pick                 # interactive numbered menu (needs a TTY)
#   just session-pick "1-4"           # ranges
#   just session-pick "1,2,4,5"       # comma list
#   just session-pick "1-3,6"         # mixed
session-pick spec="":
    bash scripts/session.sh --pick {{spec}}
