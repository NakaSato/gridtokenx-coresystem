#!/usr/bin/env bash
# GridTokenX E2E — centralized endpoints, ports, secrets.
# Source in every bash suite:  source "$(dirname "$0")/../env.sh"
# All overridable via environment for CI / alternate hosts.

# --- Gateways ---
export APISIX_URL="${APISIX_URL:-http://localhost:4001}"      # user-facing
export API_URL="${API_URL:-http://localhost:4000}"            # orchestrator / health

# --- Services ---
export IAM_URL="${IAM_URL:-http://localhost:4010}"            # REST
export IAM_GRPC="${IAM_GRPC:-localhost:5010}"
export TRADING_URL="${TRADING_URL:-http://localhost:4020}"    # REST + settlement metrics (docker host map 4020->8093)
export TRADING_GRPC="${TRADING_GRPC:-localhost:5020}"          # docker host map 5020->8092
export AGGREGATOR_BRIDGE_REST="${AGGREGATOR_BRIDGE_REST:-http://localhost:4030}"  # IoT gateway port (start.sh launches with IOT_GATEWAY_PORT=4030; the binary's internal 4010 default collides with IAM)
export AGGREGATOR_BRIDGE_GRPC="${AGGREGATOR_BRIDGE_GRPC:-localhost:50051}"  # docker-compose pins GRPC_PORT=50051 and maps host 50051:50051 (compose:655,660). The container default 5030 is NOT published — gRPC ingest (BulkRawIngest) lands on 50051.
export CHAIN_BRIDGE_GRPC="${CHAIN_BRIDGE_GRPC:-localhost:5040}"
export NOTI_GRPC="${NOTI_GRPC:-localhost:5060}"  # docker-compose publishes noti ConnectRPC at host 5060 (container 8090)
export SIMULATOR_URL="${SIMULATOR_URL:-http://localhost:12010}"

# --- Infra ---
export PG_CONTAINER="${PG_CONTAINER:-gridtokenx-postgres}"
export PG_USER="${PG_USER:-gridtokenx_user}"
export PG_DB="${PG_DB:-gridtokenx}"
export DATABASE_URL="${DATABASE_URL:-postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx}"
export REDIS_URL="${REDIS_URL:-redis://localhost:7010}"
export KAFKA_BROKER="${KAFKA_BROKER:-localhost:29001}"
# NATS work bus. Host 9020 -> container 4222 (docker-compose). The aggregator mints
# surplus directly on `chain.tx.mint` (the former meter.reading forward to
# meter-service was removed); 30_settlement subscribes here to assert the mint.
export NATS_URL_HOST="${NATS_URL_HOST:-nats://localhost:9020}"

# --- Auth / gateway ---
# Chain Bridge dev mode: when true the bridge grants Admin to every caller, so the
# 50_chain_bridge isolation cases (no-role / bogus-role rejected) cannot hold and skip.
# Mirror the running bridge (.env sets it true for local dev); CI with mTLS sets it false.
export CHAIN_BRIDGE_INSECURE="${CHAIN_BRIDGE_INSECURE:-true}"
export GATEWAY_SECRET="${GATEWAY_SECRET:-gridtokenx-gateway-secret-2025}"
export GATEWAY_HEADERS=(-H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET")
# Aggregator Bridge ingest key. Auth migrated to IAM validation (aggregator_api::auth),
# so the old static `e2e-test-key` is now rejected (401) — IAM only knows this key, which is
# the simulator's SMARTMETER_AGGREGATOR_API_KEY (docker-compose.yml:808). Single source for
# bash suites; exported into the pytest subprocess by run.sh, and mirrored in conftest.py.
export AGGREGATOR_API_KEY="${AGGREGATOR_API_KEY:-engineering-department-api-key-2025}"

# --- HTTP status sink ---
# http_json runs inside `$(...)` command substitutions (to capture the body), so any
# global it sets — including HTTP_STATUS — dies with the subshell. Persist the status to
# a file that survives, and read it back via `hs` (see lib/http.sh).
export E2E_STATUS_FILE="${E2E_STATUS_FILE:-${TMPDIR:-/tmp}/e2e_http_status.$$}"

# --- Test run identity (unique per run for isolation) ---
export E2E_RUN_ID="${E2E_RUN_ID:-$(date +%s)-$$}"
export E2E_PASSWORD="${E2E_PASSWORD:-GRX-Secure-P@ss-2026-E2E}"
