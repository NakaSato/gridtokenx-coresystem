#!/usr/bin/env bash
# bench-ingest.sh — telemetry-ingest saturation harness for the Aggregator Bridge.
#
# Closes paper review items #1 (find the throughput knee, not a self-imposed rate)
# and #2 (N repeats → mean±sd, not N=1). Ramps the signed-reading offered load
# across meter-fleet sizes, runs each step for a fixed wall-clock budget, and
# records the bridge's accept+verify+disseminate throughput and loss.
#
# PRIMARY metric = HTTP boundary: the simulator POSTs one signed OBIS frame per
# meter to /v1/private-network/ingest; a 200 means the bridge verified the Ed25519
# signature AND disseminated the reading to its zone Redis Stream. So
#   throughput = total_sent / elapsed   (readings/s actually accepted+disseminated)
#   loss       = total_failed / (total_sent + total_failed)
# This is the real measure behind the paper's "no data loss" claim.
#
# SECONDARY check = Redis XLEN delta across zone streams. NOTE: the bridge XADDs
# with MAXLEN~REDIS_STREAM_MAXLEN (router.rs), so once a stream hits the cap the
# delta UNDER-counts. Treat it as a soft sanity signal, not the loss source.
#
# Requires infra up (`just orb-up`) — Aggregator Bridge IoT gateway + Redis. No
# Solana validator needed (this is the off-chain ingest path only).
#
# Usage:
#   scripts/bench-ingest.sh
#   RAMP="40 80 160 320 640" DURATION=60 REPEATS=5 INTERVAL=0 scripts/bench-ingest.sh
set -euo pipefail

# --- Tunables (env-overridable) -------------------------------------------------
RAMP="${RAMP:-40 80 160 320 640}"          # meter-fleet sizes to sweep
DURATION="${DURATION:-60}"                  # wall-clock seconds per step
INTERVAL="${INTERVAL:-0}"                    # inter-tick sleep (0 = max offered rate)
REPEATS="${REPEATS:-5}"                      # runs per step (for mean±sd)
ZONES="${ZONES:-10}"                         # IOT_NUM_ZONES (zone_0..zone_{N-1})
REDIS_URL="${REDIS_URL:-redis://localhost:7010}"
BRIDGE_URL="${BRIDGE_URL:-http://localhost:4030}"
SETTLE="${SETTLE:-3}"                         # grace secs for async dissemination to drain
OUT="${OUT:-bench-ingest-results.csv}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="$ROOT/gridtokenx-smartmeter-simulator/backend"

command -v redis-cli >/dev/null || { echo "redis-cli not found (brew install redis)"; exit 1; }
command -v uv >/dev/null || { echo "uv not found"; exit 1; }

# --- Environment provenance (review #11: record hardware + config) --------------
echo "# bench-ingest provenance"
echo "#   host:      $(uname -mnsr)"
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "#   cpu:       $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?') (${HW_NCPU:=$(sysctl -n hw.ncpu)} cores)"
  echo "#   mem:       $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 )) GiB"
fi
echo "#   commit:    $(git -C "$ROOT" rev-parse --short HEAD)"
echo "#   bridge:    $BRIDGE_URL    redis: $REDIS_URL    zones: $ZONES"
echo "#   ramp:      [$RAMP]  duration=${DURATION}s  interval=${INTERVAL}  repeats=$REPEATS"
echo "#"

# Bridge reachable?
curl -fsS "$BRIDGE_URL/health" >/dev/null 2>&1 || {
  echo "ERROR: bridge $BRIDGE_URL/health unreachable — run 'just orb-up' first" >&2; exit 1; }

# --- Helpers --------------------------------------------------------------------
zone_xlen_sum() {  # sum XLEN over zone_0..zone_{ZONES-1}
  local total=0 z len
  for (( z=0; z<ZONES; z++ )); do
    len=$(redis-cli -u "$REDIS_URL" XLEN "gridtokenx:events:zone_${z}" 2>/dev/null || echo 0)
    total=$(( total + ${len:-0} ))
  done
  echo "$total"
}

# --- CSV header -----------------------------------------------------------------
echo "meters,repeat,elapsed_s,sent,failed,throughput_rps,loss_frac,xlen_delta" > "$OUT"

# --- Sweep ----------------------------------------------------------------------
export AGGREGATOR_DLMS_ENABLED=true
export AGGREGATOR_BRIDGE_URL="$BRIDGE_URL"
export REDIS_URL="$REDIS_URL"

for M in $RAMP; do
  for (( r=1; r<=REPEATS; r++ )); do
    before=$(zone_xlen_sum)
    # Run the bounded, self-reporting sender; capture its BENCH_JSON line.
    # `|| true` keeps a quiet/failed step (no BENCH_JSON line) from aborting the
    # whole sweep under `set -euo pipefail` — a single bad step is logged as a
    # skipped row, not fatal.
    json=$(cd "$SIM_DIR" && uv run python scripts/send_to_aggregator_bridge.py \
             --meters "$M" --interval "$INTERVAL" --duration "$DURATION" \
             --onboard --report 2>/dev/null | grep '^BENCH_JSON ' | sed 's/^BENCH_JSON //' || true)
    sleep "$SETTLE"
    after=$(zone_xlen_sum)

    if [[ -z "$json" ]]; then
      echo "WARN: meters=$M repeat=$r produced no BENCH_JSON — recording skipped row" >&2
      echo "$M,$r,NA,NA,NA,NA,NA,$(( after - before ))" | tee -a "$OUT"
      continue
    fi

    # Parse once in Python (avoids 4 subprocesses); fall back to a skipped row on
    # malformed JSON rather than crashing the sweep.
    if ! read -r sent failed elapsed rps < <(echo "$json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(d["total_sent"], d["total_failed"], d["elapsed_s"], d["send_rate_per_s"])
' 2>/dev/null); then
      echo "WARN: meters=$M repeat=$r malformed BENCH_JSON — recording skipped row" >&2
      echo "$M,$r,NA,NA,NA,NA,NA,$(( after - before ))" | tee -a "$OUT"
      continue
    fi
    loss=$(python3 -c "s=$sent;f=$failed;print(round(f/(s+f),5) if (s+f)>0 else 0.0)")
    delta=$(( after - before ))

    echo "$M,$r,$elapsed,$sent,$failed,$rps,$loss,$delta" | tee -a "$OUT"
  done
done

echo "#"
echo "# wrote $OUT — aggregate with: scripts/bench-ingest-summary.py $OUT"
