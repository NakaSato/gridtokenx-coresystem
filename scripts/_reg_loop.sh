#!/usr/bin/env bash
set -u
cd /Users/chanthawat/Developments/gridtokenx-coresystem
for i in $(seq 1 10); do
  echo "===== BATCH $i/10 start $(date +%H:%M:%S) ====="
  bash scripts/register_users_meters.sh 80 > "scripts/reg_loop_logs/batch_${i}.log" 2>&1
  rc=$?
  ok=$(rg -c 'signing wired' "scripts/reg_loop_logs/batch_${i}.log" 2>/dev/null || echo 0)
  echo "===== BATCH $i/10 done rc=$rc signing_wired=$ok $(date +%H:%M:%S) ====="
done
echo "ALL BATCHES COMPLETE $(date +%H:%M:%S)"
