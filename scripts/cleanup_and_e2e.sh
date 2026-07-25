#!/usr/bin/env bash
# Reset all service databases to empty, then run the register->trading E2E on a
# clean slate. Codifies the manual recipe (the traps below were each learned the
# hard way).
#
# What it does, in order:
#   1. TRUNCATE every app table in the 6 service DBs (keeps schema + _sqlx_migrations)
#   2. Redis FLUSHALL          (device registry, owner/wallet caches, zone streams)
#   3. restart the 6 stateful services  (clears in-process caches + cold-loads the
#                                        read-models so they re-seed from the empty DBs)
#   4. re-seed the aggregator dev API key  (TRUNCATE wiped api_keys -> ingest 401 without this)
#   5. run scripts/e2e_two_user_trade.sh   (register -> verify -> meter -> order -> settle)
#
# DESTRUCTIVE: wipes ALL data in gridtokenx{,_chain,_iam,_meter,_noti,_trading}.
# The Solana ledger is NOT touched — fresh users register fresh PDAs. Guarded:
# runs only with CONFIRM=1 or --yes.
#
# Env:
#   CONFIRM=1 / --yes   required to run (safety)
#   PG_CONTAINER        default gridtokenx-postgres
#   REDIS_CONTAINER     default gridtokenx-redis
#   SIM_REST_BASE       default http://localhost:12010  (sim's own REST; NOT 8082)
#   SETTLE_WAIT         default 15   (seconds for the matcher/settlement to drain)
#   SKIP_E2E=1          reset only, don't run the trade
set -uo pipefail

[ "${1:-}" = "--yes" ] && CONFIRM=1
if [ "${CONFIRM:-0}" != "1" ]; then
  echo "DESTRUCTIVE: truncates all 6 service DBs + FLUSHALL Redis. Re-run with CONFIRM=1 or --yes." >&2
  exit 2
fi

PG="${PG_CONTAINER:-gridtokenx-postgres}"
REDIS="${REDIS_CONTAINER:-gridtokenx-redis}"
SIM_REST_BASE="${SIM_REST_BASE:-http://localhost:12010}"
SETTLE_WAIT="${SETTLE_WAIT:-15}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DBS=(gridtokenx gridtokenx_chain gridtokenx_iam gridtokenx_meter gridtokenx_noti gridtokenx_trading)
SERVICES=(iam-service meter-service aggregator-bridge trading-service noti-service chain-bridge)

echo "== 1) TRUNCATE app tables in ${#DBS[@]} DBs (keep schema + _sqlx_migrations) =="
for db in "${DBS[@]}"; do
  # meter_readings_* are partitions of meter_readings; TRUNCATE on the parent cascades.
  tbls=$(docker exec "$PG" psql -U gridtokenx_user -d "$db" -tAc \
    "SELECT string_agg(format('%I.%I', schemaname, tablename), ',')
       FROM pg_tables
      WHERE schemaname='public'
        AND tablename <> '_sqlx_migrations'
        AND tablename NOT LIKE 'meter_readings_%'" 2>/dev/null)
  if [ -n "$tbls" ]; then
    docker exec "$PG" psql -U gridtokenx_user -d "$db" -c "TRUNCATE $tbls RESTART IDENTITY CASCADE" >/dev/null 2>&1 \
      && echo "   $db: truncated" || echo "   $db: TRUNCATE FAILED"
  else
    echo "   $db: no tables"
  fi
done

echo "== 2) Redis FLUSHALL =="
docker exec "$REDIS" redis-cli FLUSHALL | head -1

echo "== 3) restart stateful services + wait healthy =="
docker restart "${SERVICES[@]/#/gridtokenx-}" >/dev/null
for i in $(seq 1 40); do
  bad=""
  for s in "${SERVICES[@]}"; do
    [ "$(docker inspect "gridtokenx-$s" --format '{{.State.Health.Status}}' 2>/dev/null)" != "healthy" ] && bad="$bad $s"
  done
  [ -z "$bad" ] && { echo "   all healthy"; break; }
  sleep 5
done
[ -n "$bad" ] && { echo "   NOT healthy:$bad" >&2; exit 1; }

echo "== 4) re-seed aggregator dev API key (TRUNCATE wiped api_keys -> 401 without this) =="
( cd "$HERE/.." && just seed-apikey 2>&1 | grep -iE 'INSERT|SUCCESS|key=' )

if [ "${SKIP_E2E:-0}" = "1" ]; then echo "SKIP_E2E=1 -> reset only, done."; exit 0; fi

echo "== 5) run register -> trading E2E =="
SIM_REST_BASE="$SIM_REST_BASE" SETTLE_WAIT="$SETTLE_WAIT" "$HERE/e2e_two_user_trade.sh"
