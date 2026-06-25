#!/usr/bin/env bash
# OpenADR dispatch end-to-end test.
#
# Proves the full autonomous loop through the Aggregator Bridge:
#   telemetry (low frequency) -> zone ingester -> FrequencyMonitor
#   -> grid-status publisher -> Kafka -> dispatch engine
#   -> OpenADR event on the local VTN (BL side)
#   -> VEN listener consumes + executes it downstream.
#
# Infra used (superproject docker-compose): redis, kafka-cmd, openleadr-vtn,
# openleadr-vtn-db, openleadr-vtn-seed. The bridge runs as a LOCAL debug
# binary on test ports; if the gridtokenx-aggregator-bridge container is
# running it is stopped for the duration (it shares the Redis consumer group
# and Kafka group and would race the test bridge) and restarted afterwards.
#
# Usage: scripts/openleadr-e2e.sh   (or: just openadr-e2e)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BRIDGE_DIR="$ROOT/gridtokenx-aggregator-bridge"
VTN_PORT=${OPENLEADR_VTN_PORT:-4031}
VTN_URL="http://localhost:${VTN_PORT}"
HTTP_PORT=${E2E_BRIDGE_PORT:-4011}
GRPC_PORT=${E2E_BRIDGE_GRPC_PORT:-5031}
API_KEY="e2e-test-key"
TOPIC="gridtokenx.aggregator.grid_status"
BRIDGE_LOG=$(mktemp "${TMPDIR:-/tmp}/openleadr-e2e-bridge.XXXXXX")
BRIDGE_PID=""
CONTAINER_WAS_RUNNING=0

log() { printf '\033[1;34m[e2e]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[e2e] FAIL:\033[0m %s\n' "$*"; exit 1; }

cleanup() {
  if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  # The bridge is exec'd inside a subshell; killing the subshell can orphan the
  # binary itself. Sweep it by name so reruns don't inherit a stale listener.
  pkill -f "target/debug/gridtokenx-aggregator-bridge" 2>/dev/null || true
  if [[ "$CONTAINER_WAS_RUNNING" == 1 ]]; then
    log "restoring gridtokenx-aggregator-bridge container"
    docker start gridtokenx-aggregator-bridge >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

vtn_token() {
  curl -sf -X POST "$VTN_URL/auth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=bl-client&client_secret=bl-client" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])"
}

vtn_event_count() {
  curl -sf "$VTN_URL/events" -H "Authorization: Bearer $1" \
    | python3 -c "import sys,json;print(len(json.load(sys.stdin)))"
}

vtn_report_count() {
  curl -sf "$VTN_URL/reports" -H "Authorization: Bearer $1" \
    | python3 -c "import sys,json;print(len(json.load(sys.stdin)))"
}

vtn_ven_count_named() {
  # $1 token, $2 venName
  curl -sf "$VTN_URL/vens" -H "Authorization: Bearer $1" \
    | python3 -c "import sys,json;print(sum(1 for v in json.load(sys.stdin) if v.get('venName')=='$2'))"
}

# --- 1. infrastructure -------------------------------------------------------
log "starting infra (redis, kafka-cmd, VTN + db + seed)"
(cd "$ROOT" && docker compose up -d redis kafka-cmd openleadr-vtn-db openleadr-vtn openleadr-vtn-seed >/dev/null)

log "waiting for VTN auth at $VTN_URL"
TOKEN=""
for _ in $(seq 1 60); do
  TOKEN=$(vtn_token 2>/dev/null) && break || sleep 2
done
[[ -n "$TOKEN" ]] || fail "VTN token endpoint never came up (is openleadr-vtn-seed done?)"

# Pre-create the dispatch topic: a consumer that subscribes before the topic
# exists silently misses the first message (auto.offset.reset=latest).
docker exec gridtokenx-kafka-cmd /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9001 --create --if-not-exists --topic "$TOPIC" >/dev/null

# --- 2. local bridge ---------------------------------------------------------
if docker ps --format '{{.Names}}' | grep -q '^gridtokenx-aggregator-bridge$'; then
  CONTAINER_WAS_RUNNING=1
  log "stopping gridtokenx-aggregator-bridge container for the test (will restore)"
  docker stop gridtokenx-aggregator-bridge >/dev/null
fi

# A stale test bridge from an aborted run would hold the port (and its dispatch
# cooldown would suppress the event this test asserts on).
pkill -f "target/debug/gridtokenx-aggregator-bridge" 2>/dev/null || true

log "building bridge (debug)"
(cd "$BRIDGE_DIR" && cargo build --quiet)

log "starting test bridge on :$HTTP_PORT (log: $BRIDGE_LOG)"
(
  cd "$BRIDGE_DIR" && \
  env -u ENVIRONMENT \
    REDIS_URL="redis://localhost:7010" \
    KAFKA_BOOTSTRAP_SERVERS="localhost:29001" \
    GRIDTOKENX_API_KEYS="$API_KEY" \
    IAM_SERVICE_URL="http://127.0.0.1:1" \
    IOT_GATEWAY_PORT="$HTTP_PORT" \
    GRPC_PORT="$GRPC_PORT" \
    GRID_STATUS_PUBLISH_SECS=5 \
    OPENLEADR_VTN_URL="$VTN_URL" \
    OPENLEADR_CLIENT_ID=bl-client \
    OPENLEADR_CLIENT_SECRET=bl-client \
    OPENLEADR_VEN_VTN_URL="$VTN_URL" \
    OPENLEADR_VEN_CLIENT_ID=ven-client-client-id \
    OPENLEADR_VEN_CLIENT_SECRET=ven-client \
    OPENLEADR_VEN_POLL_SECS=5 \
    OPENLEADR_VEN_REPORTS=true \
    ./target/debug/gridtokenx-aggregator-bridge >"$BRIDGE_LOG" 2>&1
) &
BRIDGE_PID=$!

for _ in $(seq 1 60); do
  curl -sf -o /dev/null "http://localhost:${HTTP_PORT}/health" && break || sleep 1
done
curl -sf -o /dev/null "http://localhost:${HTTP_PORT}/health" || fail "bridge never became healthy (see $BRIDGE_LOG)"

# --- 2b. VEN self-registration ----------------------------------------------
# The listener self-registers a VEN object on the VTN at startup. Assert it
# appears (the listener polls/registers within a couple of seconds of boot).
VEN_NAME="gridtokenx-aggregator-bridge"
log "waiting for VEN self-registration on the VTN (max 20s)"
REG_OK=0
for _ in $(seq 1 10); do
  if [[ "$(vtn_ven_count_named "$TOKEN" "$VEN_NAME" 2>/dev/null || echo 0)" -ge 1 ]]; then
    REG_OK=1; break
  fi
  sleep 2
done
(( REG_OK == 1 )) || { tail -20 "$BRIDGE_LOG" >&2; fail "VEN '$VEN_NAME' never self-registered on the VTN"; }
log "VEN self-registration OK: '$VEN_NAME' present on the VTN"

# --- 3. drive the loop -------------------------------------------------------
EVENTS_BEFORE=$(vtn_event_count "$TOKEN")
REPORTS_BEFORE=$(vtn_report_count "$TOKEN")
log "VTN has $EVENTS_BEFORE events / $REPORTS_BEFORE reports; ingesting low-frequency telemetry"

# Backdated 20 min so the 15-minute aggregation bin is already complete
# (dispatch refuses to fire with zero capacity).
TS=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(minutes=20)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:${HTTP_PORT}/v1/private-network/ingest" \
  -H "Content-Type: application/json" -H "X-API-KEY: $API_KEY" \
  -d "{\"device_id\":\"openleadr-e2e-meter\",\"protocol\":\"simulator\",\"payload\":{\"energy_generated\":5.0,\"energy_consumed\":1.0,\"kwh\":4.0,\"frequency\":49.5,\"timestamp\":\"$TS\",\"zone_code\":\"E2E\"}}")
[[ "$HTTP_CODE" == 2* ]] || fail "ingest returned HTTP $HTTP_CODE"

# --- 4. assertions -----------------------------------------------------------
log "waiting for a new OpenADR event on the VTN (max 90s)"
NEW_EVENT=0
for _ in $(seq 1 45); do
  COUNT=$(vtn_event_count "$TOKEN" 2>/dev/null || echo "$EVENTS_BEFORE")
  if (( COUNT > EVENTS_BEFORE )); then NEW_EVENT=1; break; fi
  sleep 2
done
(( NEW_EVENT == 1 )) || { tail -20 "$BRIDGE_LOG" >&2; fail "no new event appeared on the VTN"; }
log "BL side OK: new dispatch event on VTN ($EVENTS_BEFORE -> $COUNT)"

log "waiting for the VEN listener to execute it (max 30s)"
VEN_OK=0
for _ in $(seq 1 15); do
  if grep -q "OpenADR VEN event executed" "$BRIDGE_LOG"; then VEN_OK=1; break; fi
  sleep 2
done
(( VEN_OK == 1 )) || { tail -20 "$BRIDGE_LOG" >&2; fail "VEN listener never executed the event"; }
log "VEN side OK: event consumed and executed"

log "waiting for the VEN execution report on the VTN (max 30s)"
REPORT_OK=0
for _ in $(seq 1 15); do
  RCOUNT=$(vtn_report_count "$TOKEN" 2>/dev/null || echo "$REPORTS_BEFORE")
  if (( RCOUNT > REPORTS_BEFORE )); then REPORT_OK=1; break; fi
  sleep 2
done
(( REPORT_OK == 1 )) || { tail -20 "$BRIDGE_LOG" >&2; fail "no execution report appeared on the VTN"; }
log "report OK: execution report posted ($REPORTS_BEFORE -> $RCOUNT)"

printf '\033[1;32m[e2e] PASS:\033[0m telemetry -> frequency window -> Kafka -> dispatch -> VTN event -> VEN execution -> report\n'
