#!/usr/bin/env bash
# 20 encrypted surplus feeds, each in a DISTINCT closed 15-min window → 20 distinct mints.
set -u
METER="${METER:-7aa41192-e292-4745-ae09-b2a6070cec33}"
KWH="${KWH:-5}"
ZONE="${ZONE:-4}"
INTERVAL="${INTERVAL:-15}"
N="${N:-20}"
OFFSET="${OFFSET:-0}"   # extra minutes back so windows don't overlap prior runs (avoid mint dedup)
SCRIPT=/Users/chanthawat/Developments/gridtokenx-coresystem/.claude/skills/telemetry-hops/scripts/force_surplus.py
cd /Users/chanthawat/Developments/gridtokenx-coresystem/gridtokenx-smartmeter-simulator/backend || exit 1
for i in $(seq 1 "$N"); do
  # step back (i*15 + 20) min → distinct already-closed window per tick
  mins=$(( i*15 + 20 + OFFSET ))
  TS=$(date -u -v-${mins}M +%Y-%m-%dT%H:%M:%S+00:00)
  now=$(date -u +%H:%M:%S)
  out=$(AGGREGATOR_BRIDGE_URL=https://localhost:4030 \
    AGGREGATOR_API_KEY=engineering-department-api-key-2025 REDIS_URL=redis://localhost:7010 \
    uv run python "$SCRIPT" --meter "$METER" --kwh "$KWH" --zone "$ZONE" --encrypt --at "$TS" 2>&1 | tail -1)
  echo "[$now] tick $i/$N ts=$TS :: $out"
  [ "$i" -lt "$N" ] && sleep "$INTERVAL"
done
echo "=== done $N ticks ==="
