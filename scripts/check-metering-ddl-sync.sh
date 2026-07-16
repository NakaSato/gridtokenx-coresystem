#!/usr/bin/env bash
# Guard: the metering registry DDL (meters, meter_registry,
# meter_verification_attempts) exists in two places under the DB-per-service
# Phase 2 "aggregator applies the complete set" model:
#
#   - gridtokenx-aggregator-bridge/migrations/0002_meter_registry.sql
#         the CANONICAL set the dedicated migrate job actually applies to
#         gridtokenx_meter (aggregator owns the complete metering schema).
#   - gridtokenx-meter-service/migrations/0001_meter_registry.sql
#         meter-service's OWNERSHIP source-of-truth for the tables it solely
#         writes (it does not run migrations; this documents what it owns).
#
# These must not drift. This script compares the *SQL statements* for the three
# tables (CREATE TABLE / INDEX / TRIGGER / COMMENT), ignoring comments and
# whitespace, and fails if they differ. Run from the superproject root; wire into
# the doc-lint gate / pre-commit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGG="$ROOT/gridtokenx-aggregator-bridge/migrations/0002_meter_registry.sql"
MS="$ROOT/gridtokenx-meter-service/migrations/0001_meter_registry.sql"

for f in "$AGG" "$MS"; do
    [ -f "$f" ] || { echo "❌ missing migration file: $f" >&2; exit 2; }
done

# Extract the registry DDL: from the first `CREATE TABLE public.meters` to EOF
# (both files carry the three tables as their tail — the meter-service file adds
# shared functions ABOVE this point, which are intentionally not compared here).
# Normalize: drop `--` comment lines and blank lines, collapse whitespace runs,
# strip leading/trailing whitespace — so only the effective SQL is compared.
extract() {
    sed -n '/CREATE TABLE public.meters/,$p' "$1" \
        | sed 's/--.*$//' \
        | grep -v '^[[:space:]]*$' \
        | tr -s '[:space:]' ' ' \
        | sed 's/^ //; s/ $//'
}

if diff <(extract "$AGG") <(extract "$MS") >/tmp/metering_ddl_sync.diff 2>&1; then
    echo "✅ metering registry DDL in sync (aggregator 0002 ↔ meter-service 0001)"
else
    echo "❌ metering registry DDL DRIFT — aggregator 0002 and meter-service 0001 disagree:" >&2
    cat /tmp/metering_ddl_sync.diff >&2
    echo "" >&2
    echo "Under 'aggregator applies the complete set', these two copies of the" >&2
    echo "meters/meter_registry/meter_verification_attempts DDL must stay identical." >&2
    exit 1
fi
