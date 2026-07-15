#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# DB-per-service Phase 1 — Trading cutover runbook (see
# docs/design-docs/db-per-service-migration.md §5).
#
# GUARDED: DRY_RUN=1 by default — prints what it WOULD do, mutates nothing.
# Run steps deliberately; this is a runbook you read, not a fire-and-forget.
# Destructive/live-stack steps (pgdog reload, env flip, service restart) are
# intentionally NOT automated here — they need a maintenance window.
#
#   DRY_RUN=1 ./phase1-trading-cutover.sh   # default: show plan
#   STEP=roles DRY_RUN=0 ./phase1-trading-cutover.sh   # run one step for real
# ---------------------------------------------------------------------------
set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
STEP="${STEP:-all}"
PG_CONTAINER="${PG_CONTAINER:-gridtokenx-postgres}"
PGUSER="${PGUSER:-gridtokenx_user}"
SRC_DB="gridtokenx"
DST_DB="gridtokenx_trading"
ROLE="trading_rw"
# 25 trading-owned tables to backfill (data copy at freeze). Read-model tables
# (iam_wallet_read_model, meter_read_model, trading_*_audit) are populated by
# the feed/backfill, NOT copied here.
TRADING_TABLES=(
  trading_orders trading_orders_archive settlements settlements_archive
  order_matches market_epochs market_epochs_archive recurring_orders
  recurring_order_executions outbox_events price_alerts vpp_clusters
  vpp_dispatch_history futures_products futures_orders futures_positions
  carbon_credits carbon_transactions p2p_orders p2p_config p2p_config_audit
  swap_transactions liquidity_pools platform_revenue escrow_records
)

run() { # run <description> <sql-or-cmd...>
  echo "  → $1"
  if [[ "$DRY_RUN" == "1" ]]; then echo "    [dry-run] ${*:2}"; else "${@:2}"; fi
}
psql_dst() { docker exec -i "$PG_CONTAINER" psql -U "$PGUSER" -d "$DST_DB" -v ON_ERROR_STOP=1 "$@"; }

echo "=== Phase 1 Trading cutover  (DRY_RUN=$DRY_RUN, STEP=$STEP) ==="

# --- STEP roles: least-privilege DB role, grants ONLY on gridtokenx_trading ---
if [[ "$STEP" == "all" || "$STEP" == "roles" ]]; then
  echo "[1] least-priv role $ROLE"
  SQL_ROLE="
    DO \$\$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${ROLE}') THEN
        CREATE ROLE ${ROLE} LOGIN PASSWORD 'CHANGE_ME_trading_pw';
      END IF;
    END \$\$;
    GRANT CONNECT ON DATABASE ${DST_DB} TO ${ROLE};
    GRANT USAGE ON SCHEMA public TO ${ROLE};
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${ROLE};
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${ROLE};
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO ${ROLE};
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE,SELECT ON SEQUENCES TO ${ROLE};"
  run "create role + grants scoped to ${DST_DB} only" psql_dst -c "$SQL_ROLE"
fi

# --- STEP backfill: copy trading table rows src -> dst (at freeze) ---
if [[ "$STEP" == "all" || "$STEP" == "backfill" ]]; then
  echo "[2] data backfill ${SRC_DB} -> ${DST_DB} (FK-safe: disable triggers during copy)"
  for t in "${TRADING_TABLES[@]}"; do
    CMD="docker exec ${PG_CONTAINER} bash -c \"pg_dump -U ${PGUSER} -d ${SRC_DB} --data-only --no-owner -t public.${t} | psql -U ${PGUSER} -d ${DST_DB} -v ON_ERROR_STOP=1 --single-transaction -c 'SET session_replication_role=replica;' -f -\""
    run "copy ${t}" bash -c "$CMD"
  done
  echo "  NOTE: run inside a write-freeze (stop trading-service) so no rows are missed."
fi

# --- STEP verify: row-count parity src vs dst ---
if [[ "$STEP" == "all" || "$STEP" == "verify" ]]; then
  echo "[3] row-count parity check"
  for t in "${TRADING_TABLES[@]}"; do
    if [[ "$DRY_RUN" == "1" ]]; then echo "    [dry-run] compare count($t)"; else
      s=$(docker exec "$PG_CONTAINER" psql -U "$PGUSER" -d "$SRC_DB" -tAc "SELECT count(*) FROM public.$t" 2>/dev/null || echo NA)
      d=$(docker exec "$PG_CONTAINER" psql -U "$PGUSER" -d "$DST_DB" -tAc "SELECT count(*) FROM public.$t" 2>/dev/null || echo NA)
      [[ "$s" == "$d" ]] && echo "    OK   $t: $s" || echo "    DIFF $t: src=$s dst=$d"
    fi
  done
fi

cat <<'MANUAL'

=== MANUAL steps (NOT automated — maintenance window, live stack) ===
  A. Apply code cutover in gridtokenx-trading-service (a branch, then bump pointer):
       - re-apply audit repoint: user_activities -> trading_user_activities,
         wallet_audit_log -> trading_wallet_audit_log (the TODO(db-split) sites)
       - swap reads: get_user_primary_wallet -> iam_wallet_read_model;
         vpp.rs meters JOIN -> meter_read_model
  B. Enable feeds first + let read-models populate BEFORE the flip:
       IAM already emits; set METER_EVENTS_ENABLED=true; set TRADING_READMODEL_FEED=true
       (boot backfill runs). Verify iam_wallet_read_model / meter_read_model non-empty.
  C. Reload pgdog (picks up the gridtokenx_trading route) — brief conn blip.
  D. Freeze trading writes; run this script STEP=backfill then STEP=verify.
  E. Flip TRADING_DATABASE_URL -> postgresql://trading_rw@pgdog:6432/gridtokenx_trading
     and restart trading-service. Fix docker-compose.yml:916 "schema" comment.
  F. just e2e + trading suite.  ROLLBACK: point TRADING_DATABASE_URL back at
     gridtokenx (source tables untouched until a later cleanup migration drops them).
MANUAL
echo "=== end (DRY_RUN=$DRY_RUN) ==="
