#!/usr/bin/env bash
# Suite 85 — VPP demand-response over OpenADR (OpenLEADR VTN ↔ VEN).
#
# Brings the frequency-driven dispatch path under the numbered e2e harness. It
# delegates to the self-contained scripts/openleadr-e2e.sh (also `just openadr-e2e`),
# which proves the full autonomous loop:
#
#   low-frequency telemetry -> zone ingester -> FrequencyMonitor -> grid-status
#   publisher -> Kafka -> dispatch engine -> OpenADR event on the local VTN (BL)
#   -> VEN listener consumes + executes -> execution report posted back to the VTN.
#
# HEAVY + INVASIVE, so it is OFF by default (gate E2E_RUN_OPENADR=1):
#   - cargo-builds the aggregator-bridge debug binary and runs it on test ports;
#   - `docker compose up` for redis, kafka-cmd, openleadr-vtn{,-db,-seed};
#   - STOPS the running gridtokenx-aggregator-bridge container for the duration
#     (it shares the Redis/Kafka consumer groups and would race), restoring it after.
# Because it stops the prod-dev bridge, never fold it into the default `run.sh` pass.
#
# Run: E2E_RUN_OPENADR=1 bash tests/e2e/85_openadr/run.sh   (or: just openadr-e2e)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
SCRIPT="$ROOT/scripts/openleadr-e2e.sh"

echo "=== OpenADR / VPP Suite | run $E2E_RUN_ID ==="

if [ "${E2E_RUN_OPENADR:-0}" != "1" ]; then
    log_warn "OpenADR suite skipped (set E2E_RUN_OPENADR=1 — slow: cargo build + VTN stack, stops the bridge container)"
    suite_summary; exit 0
fi

if [ ! -f "$SCRIPT" ]; then
    log_warn "scripts/openleadr-e2e.sh not found — skipping"
    suite_summary; exit 0
fi

for bin in docker cargo python3 curl; do
    if ! command -v "$bin" >/dev/null; then
        log_warn "$bin not on PATH — skipping (OpenADR test toolchain required)"
        suite_summary; exit 0
    fi
done

# Docker daemon must be up (the script does `docker compose up` + container stop/start).
if ! docker info >/dev/null 2>&1; then
    log_warn "docker daemon unreachable — skipping OpenADR suite"
    suite_summary; exit 0
fi

OUT="${TMPDIR:-/tmp}/e2e-openadr-${E2E_RUN_ID}.log"
log_info "Running OpenADR dispatch e2e (telemetry → dispatch → VTN event → VEN exec → report)"
bash "$SCRIPT" >"$OUT" 2>&1
RC=$?

if [ "$RC" -eq 0 ] && grep -q "PASS:" "$OUT"; then
    log_success "OpenADR dispatch loop passed (VTN event + VEN execution + report)"
else
    log_fail "OpenADR dispatch loop failed (rc=$RC) — see $OUT"
    tail -25 "$OUT"
fi

suite_summary
