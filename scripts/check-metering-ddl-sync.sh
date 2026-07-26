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
#
# It guards a SECOND pair as well — the cross-service READ contract (TD-004):
#
#   - gridtokenx-aggregator-bridge/migrations/0007_user_wallet_read_model.sql
#         the writer's canonical DDL (the aggregator's IAM-event feed is the sole
#         writer of user_wallet_read_model).
#   - gridtokenx-meter-service/contracts/user_wallet_read_model.sql
#         meter-service's copy of a table it READS but does not own. Not a
#         migration, applied by nothing.
#
# meter-service resolves every owner wallet through that one table, so a shape
# change on the writer's side must fail here rather than surface as a runtime SQL
# error in a service that never migrates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGG="$ROOT/gridtokenx-aggregator-bridge/migrations/0002_meter_registry.sql"
MS="$ROOT/gridtokenx-meter-service/migrations/0001_meter_registry.sql"
AGG_UW="$ROOT/gridtokenx-aggregator-bridge/migrations/0007_user_wallet_read_model.sql"
MS_UW="$ROOT/gridtokenx-meter-service/contracts/user_wallet_read_model.sql"

for f in "$AGG" "$MS" "$AGG_UW" "$MS_UW"; do
    [ -f "$f" ] || { echo "❌ missing migration file: $f" >&2; exit 2; }
done

# Extract the registry DDL: from the first `CREATE TABLE public.meters` to EOF
# (both files carry the three tables as their tail — the meter-service file adds
# shared functions ABOVE this point, which are intentionally not compared here).
# Normalize: drop `--` comment lines and blank lines, collapse whitespace runs,
# strip leading/trailing whitespace — so only the effective SQL is compared.
extract() {
    sed -n "/CREATE TABLE public.$2/,\$p" "$1" \
        | sed 's/--.*$//' \
        | grep -v '^[[:space:]]*$' \
        | tr -s '[:space:]' ' ' \
        | sed 's/^ //; s/ $//'
}

rc=0

if diff <(extract "$AGG" meters) <(extract "$MS" meters) >/tmp/metering_ddl_sync.diff 2>&1; then
    echo "✅ metering registry DDL in sync (aggregator 0002 ↔ meter-service 0001)"
else
    echo "❌ metering registry DDL DRIFT — aggregator 0002 and meter-service 0001 disagree:" >&2
    cat /tmp/metering_ddl_sync.diff >&2
    echo "" >&2
    echo "Under 'aggregator applies the complete set', these two copies of the" >&2
    echo "meters/meter_registry/meter_verification_attempts DDL must stay identical." >&2
    rc=1
fi

if diff <(extract "$AGG_UW" user_wallet_read_model) \
        <(extract "$MS_UW" user_wallet_read_model) >/tmp/user_wallet_ddl_sync.diff 2>&1; then
    echo "✅ user_wallet_read_model contract in sync (aggregator 0007 ↔ meter-service contracts/)"
else
    echo "❌ user_wallet_read_model CONTRACT DRIFT — writer (aggregator 0007) and reader" >&2
    echo "   (meter-service contracts/user_wallet_read_model.sql) disagree:" >&2
    cat /tmp/user_wallet_ddl_sync.diff >&2
    echo "" >&2
    echo "meter-service resolves every owner wallet through this table and never runs" >&2
    echo "migrations, so a writer-side shape change must be mirrored into its contract" >&2
    echo "copy (and its queries checked) before it lands. See TD-004." >&2
    rc=1
fi

exit "$rc"
