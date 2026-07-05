#!/usr/bin/env bash
# cluster-down.sh — stop the local multi-node cluster started by cluster-up.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${CLUSTER_DIR:-$ROOT/.cluster}"

if [ ! -d "$WORK" ]; then echo "no cluster dir at $WORK"; exit 0; fi

for pidf in "$WORK"/node-*.pid; do
  [ -e "$pidf" ] || continue
  pid="$(cat "$pidf")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "killing $(basename "$pidf" .pid) pid=$pid"
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$pidf"
done

# belt-and-suspenders: any stray validators on our ports
pkill -f "agave-validator .*$WORK" 2>/dev/null || true
pkill -f "solana-validator .*$WORK" 2>/dev/null || true

if [ "${PURGE:-0}" = "1" ]; then rm -rf "$WORK"; echo "purged $WORK"; fi
echo "cluster down."
