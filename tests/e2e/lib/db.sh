#!/usr/bin/env bash
# GridTokenX E2E — Postgres helpers for bash suites (docker exec psql).
# Mirrors scripts/test-registration-e2e.sh. Source after env.sh.

# db_scalar <sql> — echo first value, whitespace-trimmed.
db_scalar() {
    docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -t -A -c "$1" 2>/dev/null | head -n1 | tr -d '[:space:]'
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

# db_cleanup_e2e — drop rows created by e2e runs.
db_cleanup_e2e() {
    docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -c "DELETE FROM users WHERE username LIKE 'e2e_%' OR email LIKE '%@grx.test';" >/dev/null 2>&1
}
