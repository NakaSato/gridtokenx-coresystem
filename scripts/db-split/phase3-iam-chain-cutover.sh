#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# DB-per-service Phase 3 — IAM + Chain-Bridge cutover runbook
# (gridtokenx-iam-service/docs/db-split-phase3.md + design-docs §3.3/§3.4).
#
# Two independent services, one runbook:
#   IAM  -> gridtokenx_iam  (users, user_wallets, api_keys, iam_outbox_events)
#   chain-> gridtokenx_chain (audit_log, dedup_effects, nonce_allocations)
#
# GUARDED: DRY_RUN=1 default. Live steps (runner repoint, env flip, restart,
# nonce seeding) are the MANUAL block.
#   DRY_RUN=1 ./phase3-iam-chain-cutover.sh
#   STEP=iam-roles DRY_RUN=0 ./phase3-iam-chain-cutover.sh
# ---------------------------------------------------------------------------
set -euo pipefail
DRY_RUN="${DRY_RUN:-1}"; STEP="${STEP:-all}"
PG_CONTAINER="${PG_CONTAINER:-gridtokenx-postgres}"; PGUSER="${PGUSER:-gridtokenx_user}"
SRC_DB="gridtokenx"
IAM_TABLES=( users user_wallets api_keys iam_outbox_events )

run() { echo "  → $1"; if [[ "$DRY_RUN" == "1" ]]; then echo "    [dry-run] ${*:2}"; else "${@:2}"; fi; }
psql_db() { docker exec -i "$PG_CONTAINER" psql -U "$PGUSER" -d "$1" -v ON_ERROR_STOP=1 "${@:2}"; }

echo "=== Phase 3 IAM+Chain cutover (DRY_RUN=$DRY_RUN, STEP=$STEP) ==="

# ---- IAM ----
if [[ "$STEP" == "all" || "$STEP" == "iam-roles" ]]; then
  echo "[IAM 1] least-priv role iam_rw on gridtokenx_iam"
  SQL="
    DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='iam_rw') THEN
      CREATE ROLE iam_rw LOGIN PASSWORD 'CHANGE_ME_iam_pw'; END IF; END \$\$;
    GRANT CONNECT ON DATABASE gridtokenx_iam TO iam_rw;
    GRANT USAGE ON SCHEMA public TO iam_rw;
    GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO iam_rw;
    GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO iam_rw;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO iam_rw;"
  run "iam_rw + grants (gridtokenx_iam only)" psql_db gridtokenx_iam -c "$SQL"
fi
if [[ "$STEP" == "all" || "$STEP" == "iam-backfill" ]]; then
  echo "[IAM 2] data backfill: drain iam_outbox_events first, then copy 4 tables"
  for t in "${IAM_TABLES[@]}"; do
    CMD="docker exec ${PG_CONTAINER} bash -c \"pg_dump -U ${PGUSER} -d ${SRC_DB} --data-only --no-owner -t public.${t} | psql -U ${PGUSER} -d gridtokenx_iam -v ON_ERROR_STOP=1 --single-transaction -c 'SET session_replication_role=replica;' -f -\""
    run "copy ${t}" bash -c "$CMD"
  done
fi
if [[ "$STEP" == "all" || "$STEP" == "iam-verify" ]]; then
  echo "[IAM 3] row-count parity"
  for t in "${IAM_TABLES[@]}"; do
    if [[ "$DRY_RUN" == "1" ]]; then echo "    [dry-run] compare count($t)"; else
      s=$(docker exec "$PG_CONTAINER" psql -U "$PGUSER" -d "$SRC_DB" -tAc "SELECT count(*) FROM public.$t" 2>/dev/null||echo NA)
      d=$(docker exec "$PG_CONTAINER" psql -U "$PGUSER" -d gridtokenx_iam -tAc "SELECT count(*) FROM public.$t" 2>/dev/null||echo NA)
      [[ "$s" == "$d" ]] && echo "    OK   $t: $s" || echo "    DIFF $t: src=$s dst=$d"
    fi; done
fi

# ---- Chain-bridge ----
if [[ "$STEP" == "all" || "$STEP" == "chain-roles" ]]; then
  echo "[CHAIN 1] recreate gridtokenx_chain + role chain_rw (audit_log/dedup/nonce)"
  run "create DB" docker exec "$PG_CONTAINER" psql -U "$PGUSER" -d postgres -c "CREATE DATABASE gridtokenx_chain OWNER ${PGUSER};"
  SQL="
    DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='chain_rw') THEN
      CREATE ROLE chain_rw LOGIN PASSWORD 'CHANGE_ME_chain_pw'; END IF; END \$\$;
    GRANT CONNECT ON DATABASE gridtokenx_chain TO chain_rw;"
  run "chain_rw role" psql_db gridtokenx_chain -c "$SQL"
fi

cat <<'MANUAL'

=== MANUAL steps (maintenance window, live stack) ===
  IAM:
  A. Repoint the migration runner: bin/iam-service/src/startup.rs
       sqlx::migrate!("../../migrations")  ->  "../../migrations-iam"
     (build gridtokenx_iam from the lean set; run cargo sqlx prepare if needed).
  B. Point IAM_DATABASE_URL / DATABASE_URL at pgdog:6432/gridtokenx_iam
     (add [[databases]] gridtokenx_iam + _migrate to pgdog.toml).
  C. Freeze IAM writes; run STEP=iam-backfill then STEP=iam-verify.
  D. Restart IAM. Smoke: register -> verify -> login -> wallet link -> outbox drains.
     ROLLBACK: revert startup.rs + DATABASE_URL to gridtokenx; DB untouched.
  E. Drop the audit_log CREATE from IAM's set: the shared-DB copy came from
     migrations/20260620000000_add_chain_bridge_audit_log.sql — audit_log is now
     chain-bridge-owned (migrations-iam/ already omits it).

  CHAIN-BRIDGE (lands with its in-flight persistence refactor — needs the
  infra db runner committed first):
  F. Apply migrations 0001..0004 to gridtokenx_chain (the runner does this at
     boot once CHAIN_BRIDGE_DATABASE_URL is set).
  G. Point CHAIN_BRIDGE_DATABASE_URL at pgdog:6432/gridtokenx_chain.
  H. SEED the nonce pool operationally: nonce_allocations rows must reference
     real on-chain durable-nonce accounts (account, authority, current value);
     the migration creates the table only. Without seeding, allocate() returns
     "durable-nonce pool exhausted or unseeded" (by design, never fabricates).
  I. Restart chain-bridge. Verify: audit hash-chain appends, effect dedup,
     nonce lease/release. ROLLBACK: unset CHAIN_BRIDGE_DATABASE_URL -> in-memory
     fallbacks (single-replica) or back to shared gridtokenx.
MANUAL
echo "=== end (DRY_RUN=$DRY_RUN) ==="
