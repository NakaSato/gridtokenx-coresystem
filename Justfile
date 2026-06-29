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

# Telemetry-ingest saturation benchmark (paper review #1/#2): ramp signed-reading
# load across meter-fleet sizes, measure Aggregator Bridge accept+verify+disseminate
# throughput + loss over N repeats. Needs `just orb-up` (bridge :4030 + Redis :7010);
# NO validator. Tune via env: RAMP, DURATION, INTERVAL, REPEATS. Summarize with
# `scripts/bench-ingest-summary.py bench-ingest-results.csv`.
bench-ingest:
    bash scripts/bench-ingest.sh

# Settlement compute-unit benchmark (paper review #3): runs the golden escrow
# settlement test and logs `BENCH_SETTLE_CU {compute_units}` for the
# settle_offchain_match instruction. CU is the meaningful, validator-independent
# on-chain cost metric (localnet latency is not representative). Needs anchor +
# a validator/surfpool. Grep output for BENCH_SETTLE_CU.
bench-settlement:
    #!/usr/bin/env bash
    set -euo pipefail
    cd gridtokenx-anchor
    # pipefail makes anchor's exit status govern (tee would otherwise mask a failed
    # test); the grep just extracts the CU line and must not fail the recipe.
    anchor test tests/escrow_settlement.ts 2>&1 | tee /tmp/bench-settlement.log
    grep -E 'BENCH_SETTLE_CU|settles a signed' /tmp/bench-settlement.log || \
      echo "(no BENCH_SETTLE_CU — test did not reach the settle path)"

# --- Solana Localnet ---

# Start local solana test validator
solana-up:
    ./scripts/app.sh solana start

# SOLANA_RESET=0 is honored by scripts/lib/common.sh::solana_validator_start; TTL=0
# disables the auto-kill timer so the resumed ledger isn't reaped mid-session.
# Start validator PRESERVING the existing test-ledger (no --reset, no chain-reseed needed)
solana-up-keep:
    with-env {SOLANA_RESET: "0", SOLANA_VALIDATOR_TTL: "0"} { ./scripts/app.sh solana start }

# Stop local solana test validator
solana-down:
    ./scripts/app.sh solana stop

# Re-seed on-chain accounts after a validator ledger reset (mints/registry/shards,
# correct registry authority) WITHOUT rebuilding/redeploying programs. Use when IAM
# verify / register_user simulation fails (InvalidMint / AccountOwnedByWrongProgram /
# UnauthorizedAuthority) but programs are still deployed.
chain-reseed:
    ./scripts/app.sh reseed

# Seed/repair the dev API key in IAM so bridge ingest authenticates. Recomputes the
# HMAC the running IAM binary expects (fixes legacy-hash vs HMAC-migrated-DB drift).
seed-apikey:
    ./scripts/app.sh seed-apikey

# Drift guard: ask live IAM whether the dev key validates (bridge ingest auth).
# Append --fix to auto-repair: just check-apikey --fix
check-apikey *args:
    ./scripts/app.sh check-apikey {{args}}

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

# --- Smart-meter telemetry security (TLS/mTLS, AES-GCM, Vault-KEK rotation) ---

# Provision the Vault Transit KEK that wraps per-meter GUEKs (idempotent; the
# dev Vault is in-memory, so re-run after `just orb-up`).
provision-kek:
    bash scripts/provision-meter-kek.sh

# Rotate per-meter encryption keys. No arg = whole keyed fleet; pass a meter_id
# to rotate one. Needs the sim up with AGGREGATOR_KEY_ROTATION_ENABLED=true.
rotate-keys meter="":
    #!/usr/bin/env bash
    set -euo pipefail
    port="${SMARTMETER_PORT:-12010}"
    if [ -n "{{meter}}" ]; then body='{"meter_id":"{{meter}}"}'; else body='{}'; fi
    curl -s -X POST "http://localhost:${port}/api/v1/simulation/keys/rotate" \
      -H 'Content-Type: application/json' -d "$body" | python3 -m json.tool

# Show each meter's current encryption key version (kid).
key-status:
    #!/usr/bin/env bash
    set -euo pipefail
    port="${SMARTMETER_PORT:-12010}"
    curl -s "http://localhost:${port}/api/v1/simulation/keys/status" | python3 -m json.tool

# Tail the sim's outbound DLMS ingest status to the bridge (the httpx POST lines):
# a quick "is telemetry flowing and accepted (202)?" check.
sim-ingest:
    #!/usr/bin/env bash
    set -euo pipefail
    docker logs gridtokenx-smartmeter-simulator --since 30s 2>&1 \
      | grep -oE 'private-network/ingest "HTTP/1.1 [0-9]+ [A-Za-z ]+"' | sort | uniq -c

# Tail recent sim logs (default 2m).
sim-logs since="2m":
    docker logs gridtokenx-smartmeter-simulator --since {{since}}

# Bring the stack up in SECURE mode: all telemetry hardening on (mTLS, AES-GCM,
# Vault-KEK rotation, ingest lockdown) by layering secure.env over .env. Ensures
# the Vault KEK exists first. Run `just gen-certs` once beforehand for the certs.
secure-up: provision-kek
    docker compose --env-file .env --env-file secure.env up -d

# Bring the stack up in plain DEV mode (.env only; security flags default off).
dev-up:
    docker compose up -d

# Hot-reload the Aggregator Bridge with cargo-watch (no docker rebuild per Rust
# change). First boot is a cold debug build; edits then recompile in seconds.
# Logs: `docker compose logs -f aggregator-bridge`.
bridge-dev:
    docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d aggregator-bridge

# Revert the bridge to the normal built image.
bridge-prod:
    docker compose up -d aggregator-bridge
