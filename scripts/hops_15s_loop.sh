#!/usr/bin/env bash
# Continuous encrypted smartmeter feed @ 15s for telemetry-hops testing.
set -u
METER="${METER:-7aa41192-e292-4745-ae09-b2a6070cec33}"
KWH="${KWH:-5}"
ZONE="${ZONE:-4}"
INTERVAL="${INTERVAL:-15}"
SCRIPT=/Users/chanthawat/Developments/gridtokenx-coresystem/.claude/skills/telemetry-hops/scripts/force_surplus.py
BACKDIR=/Users/chanthawat/Developments/gridtokenx-coresystem/gridtokenx-smartmeter-simulator/backend
cd "$BACKDIR" || exit 1
n=0
while true; do
  n=$((n+1))
  ts=$(date -u +%H:%M:%S)
  out=$(AGGREGATOR_BRIDGE_URL=https://localhost:4030 \
    AGGREGATOR_API_KEY=engineering-department-api-key-2025 REDIS_URL=redis://localhost:7010 \
    uv run python "$SCRIPT" --meter "$METER" --kwh "$KWH" --zone "$ZONE" --encrypt 2>&1 | tail -1)
  echo "[$ts] tick#$n $out"
  sleep "$INTERVAL"
done
