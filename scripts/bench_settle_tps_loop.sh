#!/usr/bin/env bash
# Loop the batch_settle_tps sweep, appending each run's TPS summary to a results log.
# Stop with: TaskStop <id>  (or Ctrl-C if foreground).
set -u
AN=/Users/chanthawat/Developments/gridtokenx-coresystem/gridtokenx-anchor
WALLET=/Users/chanthawat/Developments/gridtokenx-coresystem/dev-wallet.json
URL="${ANCHOR_PROVIDER_URL:-http://127.0.0.1:8899}"
CONC="${BENCH_TPS_CONC:-4,8}"
RESULTS="${RESULTS:-$AN/test-results/batch_settle_tps_loop.csv}"
GAP="${GAP:-10}"   # seconds between iterations
mkdir -p "$(dirname "$RESULTS")"
[ -f "$RESULTS" ] || echo "iter,epoch,conc,tps,slot_tps,wall_ms,ok,fail,cu_mean" > "$RESULTS"

cd "$AN" || exit 1
iter=0
while true; do
  iter=$((iter+1))
  epoch=$(date -u +%s)
  echo "=== iter $iter (epoch $epoch) load=$(uptime | grep -o 'load aver.*') ==="
  out=$(ANCHOR_PROVIDER_URL="$URL" ANCHOR_WALLET="$WALLET" BENCH_TPS_CONC="$CONC" \
    npx mocha -r tsx tests/batch_settle_tps.ts --timeout 1000000 2>&1)
  # Parse the "conc=N ... tps=X" + slot line pairs.
  echo "$out" | grep -E 'BENCH_BATCH_TPS\] spread=|BENCH_BATCH_SLOTTPS\]' | \
    awk -v it="$iter" -v ep="$epoch" '
      /BENCH_BATCH_TPS\] spread=/ {
        for(i=1;i<=NF;i++){split($i,a,"=");v[a[1]]=a[2]}
        conc=v["conc"]; tps=v["tps"]; wall=v["wall_ms"]; ok=v["ok"]; fail=v["fail"]; cu=v["cu_mean"]
      }
      /BENCH_BATCH_SLOTTPS\]/ {
        for(i=1;i<=NF;i++){split($i,a,"=");v2[a[1]]=a[2]}
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n", it,ep,conc,tps,v2["slot_tps"],wall,ok,fail,cu
      }' | tee -a "$RESULTS"
  # Fail signal
  echo "$out" | grep -qE '[0-9]+ passing' || echo "iter $iter: NO PASS — check run"
  sleep "$GAP"
done
