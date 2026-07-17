#!/usr/bin/env bash
# GridTokenX E2E — Postgres helpers for bash suites (docker exec psql).
# Mirrors scripts/test-registration-e2e.sh. Source after env.sh.
#
# DB-per-service aware (mirrors lib/db.py): a query routes to the database owning
# the tables it names. Each PG_DB_* defaults to the shared PG_DB, so pre-cutover
# this is a no-op; post a phase flip, export that phase's env (e.g.
# PG_DB_IAM=gridtokenx_iam) so bash-suite assertions hit the DB where the data
# actually lives. See docs/design-docs/db-per-service-migration.md §5c (#6b).

PG_DB="${PG_DB:-gridtokenx}"
PG_DB_IAM="${PG_DB_IAM:-$PG_DB}"
PG_DB_TRADING="${PG_DB_TRADING:-$PG_DB}"
PG_DB_METER="${PG_DB_METER:-$PG_DB}"
PG_DB_CHAIN="${PG_DB_CHAIN:-$PG_DB}"

# _db_route <sql> — echo the DB owning the tables the SQL names. Scans FROM/JOIN/
# UPDATE/INTO <table> plus any `table_name='<t>'` filter (information_schema
# probes). First table that maps to a non-shared DB wins; else PG_DB. Post-split a
# single statement never spans two service DBs, so first-match is sufficient.
_db_route() {
    local sql tbl target
    sql=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    for tbl in $(printf '%s' "$sql" \
        | grep -oE "(from|join|update|into)[[:space:]]+[a-z_][a-z0-9_]*|table_name[[:space:]]*=[[:space:]]*'[a-z_][a-z0-9_]*'" \
        | grep -oE "[a-z_][a-z0-9_]*'?$" | tr -d "'"); do
        case "$tbl" in
            users|user_wallets|api_keys|iam_outbox_events) target="$PG_DB_IAM" ;;
            trading_orders|order_matches|settlements|market_epochs|p2p_orders|p2p_config|vpp_clusters|outbox_events|trading_user_activities|trading_wallet_audit_log) target="$PG_DB_TRADING" ;;
            meters|meter_registry|meter_readings|oracle_submissions) target="$PG_DB_METER" ;;
            audit_log|dedup_effects|nonce_allocations) target="$PG_DB_CHAIN" ;;
            *) target="" ;;
        esac
        if [ -n "$target" ] && [ "$target" != "$PG_DB" ]; then
            printf '%s' "$target"; return
        fi
    done
    printf '%s' "$PG_DB"
}

# db_scalar <sql> — echo first value, whitespace-trimmed. Auto-routes by table.
db_scalar() {
    docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$(_db_route "$1")" -t -A -c "$1" 2>/dev/null | head -n1 | tr -d '[:space:]'
}

# db_verify_token <user_id> — real email verification token from users table.
db_verify_token() {
    db_scalar "SELECT email_verification_token FROM users WHERE id = '$1';"
}

# IAM stores the wallet private key AES-256-GCM-encrypted at rest (salt + version columns);
# there is no `ows_wallet_id` / per-wallet Vault file (Vault Transit is Chain Bridge signing).
# db_wallet_salt <username> — presence proves the key is encrypted at rest.
db_wallet_salt() {
    db_scalar "SELECT wallet_salt FROM users WHERE username = '$1';"
}

# db_wallet_enc_version <username> — wallet encryption scheme version.
db_wallet_enc_version() {
    db_scalar "SELECT wallet_encryption_version FROM users WHERE username = '$1';"
}

# db_plaintext_key_columns — count of any plaintext private-key columns on users (expect 0).
db_plaintext_key_columns() {
    db_scalar "SELECT count(*) FROM information_schema.columns WHERE table_name='users' AND column_name IN ('private_key','wallet_private_key','secret_key');"
}

# reset_register_rate_limit — clear IAM's per-IP /register throttle counter in Redis.
# IAM caps /register at 5/hour per IP (rate_limit.rs:22), keyed `iam:rate_limit:/register:{ip}`
# (keys.rs:41). A full suite provisions far more than 5 users, so flush before registering to
# keep bash suites repeatable. Best-effort: redis container absent → silently continue.
REDIS_CONTAINER="${REDIS_CONTAINER:-gridtokenx-redis}"
reset_register_rate_limit() {
    docker exec -i "$REDIS_CONTAINER" sh -c \
        "redis-cli --scan --pattern 'iam:rate_limit:/register:*' | xargs -r redis-cli DEL" \
        >/dev/null 2>&1 || true
}

# db_cleanup_e2e — drop rows created by e2e runs (users live in the IAM DB).
db_cleanup_e2e() {
    local sql="DELETE FROM users WHERE username LIKE 'e2e_%' OR email LIKE '%@grx.test';"
    docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$(_db_route "$sql")" \
        -c "$sql" >/dev/null 2>&1
}
