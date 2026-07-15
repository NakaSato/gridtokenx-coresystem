#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# DB-per-service Phase 2 — Metering cutover runbook (docs/design-docs/
# db-per-service-migration.md §5 Phase 2 + gridtokenx-aggregator-bridge/
# docs/db-split-phase2.md).
#
# Metering is ONE bounded context sharing gridtokenx_meter: meter-service owns
# meters/meter_registry/meter_verification_attempts; aggregator owns
# meter_readings(+partitions)/oracle_submissions/grid_status_history/
# meter_owner_read_model. Both point at gridtokenx_meter.
#
# GUARDED: DRY_RUN=1 default. Live steps (feed enable, read-swap deploy, env
# flip, service restart) are the MANUAL block — not automated.
#   DRY_RUN=1 ./phase2-metering-cutover.sh
#   STEP=roles DRY_RUN=0 ./phase2-metering-cutover.sh
# ---------------------------------------------------------------------------
set -euo pipefail
DRY_RUN="${DRY_RUN:-1}"; STEP="${STEP:-all}"
PG_CONTAINER="${PG_CONTAINER:-gridtokenx-postgres}"; PGUSER="${PGUSER:-gridtokenx_user}"
SRC_DB="gridtokenx"; DST_DB="gridtokenx_meter"
# meter-service owns these (registry); aggregator owns the readings/oracle/grid.
METER_SVC_TABLES=( meters meter_registry meter_verification_attempts )
AGG_TABLES=( meter_readings oracle_submissions grid_status_history )

run() { echo "  → $1"; if [[ "$DRY_RUN" == "1" ]]; then echo "    [dry-run] ${*:2}"; else "${@:2}"; fi; }
psql_dst() { docker exec -i "$PG_CONTAINER" psql -U "$PGUSER" -d "$DST_DB" -v ON_ERROR_STOP=1 "$@"; }

echo "=== Phase 2 Metering cutover (DRY_RUN=$DRY_RUN, STEP=$STEP) ==="

if [[ "$STEP" == "all" || "$STEP" == "roles" ]]; then
  echo "[1] two least-priv roles on ${DST_DB}: meter_rw (registry) + aggregator_rw (readings)"
  SQL="
    DO \$\$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='meter_rw') THEN
        CREATE ROLE meter_rw LOGIN PASSWORD 'CHANGE_ME_meter_pw'; END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='aggregator_rw') THEN
        CREATE ROLE aggregator_rw LOGIN PASSWORD 'CHANGE_ME_agg_pw'; END IF;
    END \$\$;
    GRANT CONNECT ON DATABASE ${DST_DB} TO meter_rw, aggregator_rw;
    GRANT USAGE ON SCHEMA public TO meter_rw, aggregator_rw;
    -- Both roles read/write across the shared bounded-context DB (owner-by-table
    -- is a code convention, not enforced at the grant level in the shared DB).
    GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO meter_rw, aggregator_rw;
    GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO meter_rw, aggregator_rw;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO meter_rw, aggregator_rw;"
  run "roles + grants on ${DST_DB}" psql_dst -c "$SQL"
fi

if [[ "$STEP" == "all" || "$STEP" == "backfill" ]]; then
  echo "[2] data backfill ${SRC_DB} -> ${DST_DB} (freeze registration + ingest first)"
  for t in "${METER_SVC_TABLES[@]}" "${AGG_TABLES[@]}"; do
    CMD="docker exec ${PG_CONTAINER} bash -c \"pg_dump -U ${PGUSER} -d ${SRC_DB} --data-only --no-owner -t public.${t} | psql -U ${PGUSER} -d ${DST_DB} -v ON_ERROR_STOP=1 --single-transaction -c 'SET session_replication_role=replica;' -f -\""
    run "copy ${t}" bash -c "$CMD"
  done
  echo "  NOTE: meter_readings is large + partitioned — copy per-partition or pg_dump the parent."
fi

if [[ "$STEP" == "all" || "$STEP" == "verify" ]]; then
  echo "[3] row-count parity"
  for t in "${METER_SVC_TABLES[@]}" "${AGG_TABLES[@]}"; do
    if [[ "$DRY_RUN" == "1" ]]; then echo "    [dry-run] compare count($t)"; else
      s=$(docker exec "$PG_CONTAINER" psql -U "$PGUSER" -d "$SRC_DB" -tAc "SELECT count(*) FROM public.$t" 2>/dev/null||echo NA)
      d=$(docker exec "$PG_CONTAINER" psql -U "$PGUSER" -d "$DST_DB" -tAc "SELECT count(*) FROM public.$t" 2>/dev/null||echo NA)
      [[ "$s" == "$d" ]] && echo "    OK   $t: $s" || echo "    DIFF $t: src=$s dst=$d"
    fi; done
fi

cat <<'MANUAL'

=== MANUAL steps (maintenance window, live stack) ===
  A. Enable the feeds FIRST + verify the read-model populates before any flip:
       meter-service:  METER_EVENTS_ENABLED=true
       aggregator:     AGGREGATOR_OWNER_READMODEL_FEED=true  (runs boot backfill)
     Confirm meter_owner_read_model is non-empty and tracks new registrations.
  B. Code cutover (branch, then pointer): swap the aggregator's two foreign reads
       - meter_registry.rs fetch_owner_from_db -> SELECT user_id,wallet_address
         FROM meter_owner_read_model WHERE serial_number=$1
       - pg_readings.rs -> drop JOIN users; take wallet from the read-model
       remove the TODO(db-split) markers.
  C. Apply migrations to gridtokenx_meter:
       - aggregator: set METER_DATABASE_URL=...gridtokenx_meter (its infra::db
         runs migrations/ at boot, own _sqlx_migrations ledger).
       - meter-service: relocate its registry-table migrations to run against
         gridtokenx_meter (owns meters/meter_registry/verification_attempts),
         point its DATABASE_URL at gridtokenx_meter.
  D. Freeze; run this script STEP=backfill then STEP=verify.
  E. Flip AGGREGATOR_PG_READINGS pool + meter-service DATABASE_URL to
     gridtokenx_meter (pgdog route needed — add [[databases]] gridtokenx_meter).
  F. Verify ingest -> owner-resolve (from read-model) -> zone stream -> bin ->
     surplus mint. ROLLBACK: unset METER_DATABASE_URL / point DATABASE_URL back
     at gridtokenx; source tables untouched.
MANUAL
echo "=== end (DRY_RUN=$DRY_RUN) ==="
