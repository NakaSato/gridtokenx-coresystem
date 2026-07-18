#!/bin/bash
# GridTokenX - Seed/repair the dev API key in IAM (api_keys table)
#
# Why this exists: the Aggregator Bridge authenticates ingest by calling IAM
# VerifyApiKey, which looks up `key_hash = hash_key(<key>)`. IAM's hash_key is
# HMAC-SHA256(API_KEY_SECRET, key) (crates/iam-logic/src/jwt_service.rs). If the
# seeded row's hash was written by a different scheme/secret than the running IAM
# binary computes (e.g. a legacy SHA-256(key||secret) image vs an HMAC-migrated DB),
# every ingest 401s with "API Key rejected by IAM: Invalid API Key".
#
# This recomputes the correct HMAC for the running stack's API_KEY_SECRET and
# upserts it, so the well-known dev key validates regardless of migration drift.
# Idempotent and DEV-ONLY (the key is the public dev key in GRIDTOKENX_API_KEYS).

cmd_seed_apikey() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        set -a; source "$PROJECT_ROOT/.env"; set +a
    fi
    # Must match the running IAM container's secret + the bridge's dev key.
    local secret="${API_KEY_SECRET:-test-api-key-secret-for-development-and-testing}"
    local key="${DEV_API_KEY:-engineering-department-api-key-2025}"
    local name="${DEV_API_KEY_NAME:-Engineering Default Key}"
    local role="${DEV_API_KEY_ROLE:-admin}"
    local pg_container="${PG_CONTAINER:-gridtokenx-postgres}"
    local pg_user="${POSTGRES_USER:-gridtokenx_user}"
    # api_keys lives in the IAM service DB since the db-per-service split — NOT the
    # legacy shared gridtokenx DB that POSTGRES_DB (via .env) still points at.
    local pg_db="${IAM_POSTGRES_DB:-gridtokenx_iam}"

    show_banner
    log_info "Seeding dev API key '$name' (HMAC-SHA256 over running API_KEY_SECRET)..."

    if ! docker ps --format '{{.Names}}' | grep -q "^${pg_container}$"; then
        log_error "Postgres container '$pg_container' not running — start the stack first (just orb-up)."
        return 1
    fi

    # IAM hash_key = lowercase-hex HMAC-SHA256(secret, key).
    local hash
    hash=$(printf '%s' "$key" | openssl dgst -sha256 -hmac "$secret" | awk '{print $NF}')
    if [ -z "$hash" ]; then
        log_error "Failed to compute HMAC (openssl missing?)"
        return 1
    fi
    log_info "  key=$key"
    log_info "  key_hash=$hash"

    # Upsert by NAME (api_keys has UNIQUE(key_hash), but name is not unique). Update
    # the existing row's hash in place — never insert a second row with this name,
    # which would collide on UNIQUE(key_hash) when the UPDATE then rewrites both.
    docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD:-gridtokenx_password}" "$pg_container" \
        psql -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 <<SQL
UPDATE api_keys SET key_hash = '$hash', is_active = true, role = '$role' WHERE name = '$name';
INSERT INTO api_keys (key_hash, name, role, is_active)
SELECT '$hash', '$name', '$role', true
WHERE NOT EXISTS (SELECT 1 FROM api_keys WHERE name = '$name');
SQL

    if [ $? -eq 0 ]; then
        log_success "Dev API key seeded/repaired. Verify: ./scripts/app.sh check-apikey"
    else
        log_error "Failed to upsert api_keys row."
        return 1
    fi
}

# Drift guard: ask the LIVE IAM whether the dev key validates. A "valid":false here
# means the seeded api_keys hash no longer matches what the running IAM binary
# computes (classic legacy-SHA256 image vs HMAC-migrated DB skew) — bridge ingest
# would 401. Pass --fix to auto-repair via cmd_seed_apikey and re-check.
#   ./scripts/app.sh check-apikey [--fix]
# CAVEAT: IAM caches positive verdicts in Redis (iam:api_key:<hash>,
# auth_service.rs); a freshly-broken DB row can still read VALID until that TTL
# lapses. For a definitive check after a suspected change, clear the cache key
# (redis-cli DEL "iam:api_key:<hash>") or wait out the TTL first.
cmd_check_apikey() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        set -a; source "$PROJECT_ROOT/.env"; set +a
    fi
    local fix=false
    [[ "$1" == "--fix" ]] && fix=true

    local key="${DEV_API_KEY:-engineering-department-api-key-2025}"
    # Host-published IAM gRPC/ConnectRPC port (compose: ${IAM_GRPC_PORT:-5010}->8090).
    local iam_grpc="${IAM_GRPC_URL:-http://localhost:5010}"

    show_banner
    log_info "Checking dev API key against live IAM ($iam_grpc)..."

    local resp
    resp=$(curl -s -X POST "$iam_grpc/identity.IdentityService/VerifyApiKey" \
        -H "Content-Type: application/json" \
        -H "x-gridtokenx-role: aggregator-bridge" \
        -d "{\"key\":\"$key\"}" 2>&1)

    if echo "$resp" | grep -q '"valid":true'; then
        log_success "API key VALID — IAM accepts it, bridge ingest will authenticate. ($resp)"
        return 0
    fi

    log_warn "API key INVALID — drift between seeded hash and running IAM. ($resp)"
    if [ "$fix" = true ]; then
        log_info "Repairing (--fix)..."
        cmd_seed_apikey || return 1
        resp=$(curl -s -X POST "$iam_grpc/identity.IdentityService/VerifyApiKey" \
            -H "Content-Type: application/json" \
            -H "x-gridtokenx-role: aggregator-bridge" \
            -d "{\"key\":\"$key\"}" 2>&1)
        if echo "$resp" | grep -q '"valid":true'; then
            log_success "Repaired — API key now VALID. ($resp)"
            return 0
        fi
        log_error "Still invalid after reseed — check API_KEY_SECRET matches the IAM container, or rebuild IAM. ($resp)"
        return 1
    fi
    log_warn "Run './scripts/app.sh check-apikey --fix' (or 'just seed-apikey') to repair."
    return 1
}
