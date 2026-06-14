#!/bin/bash
# GridTokenX - provision-meter / provision-meters commands
#
# Create a user (with a real Solana wallet registered on-chain via the Registry
# program) and map smart-meter id(s) to that user in Redis, so the Aggregator
# Bridge settlement engine can mint each meter's energy instead of quarantining
# it ("no registered owner (nil user)").
#
# On-chain user creation flow (mirrors scripts/iam_register_verify_onchain.sh):
#   1. register   POST /api/v1/auth/register            -> user_id (.id)
#   2. verify     GET  /api/v1/auth/verify?token=verify_<email>
#   3. login      POST /api/v1/auth/login               -> JWT
#   4. link       POST /api/v1/me/wallets         (real keypair, is_primary)
#   5. on-chain   POST /api/v1/me/registration (Registry PDA via Chain Bridge)
#   6. map        SET  gridtokenx:meters:<meter_id>:user_id = <user_id>  (Redis)
#
# Usage:
#   ./app.sh provision-meter  <meter_id> [user_type] [email]      # one meter, new user
#   USER_ID=<uuid> ./app.sh provision-meter <meter_id>            # map to existing user
#   ./app.sh provision-meters <file|-> [user_type]               # many meters, ONE shared user
#   USER_ID=<uuid> ./app.sh provision-meters <file|->            # many meters -> existing user
#     (<file> = one meter_id per line; "-" reads meter ids from stdin)
#
# Env overrides:
#   IAM_BASE         (default http://localhost:${IAM_HTTP_PORT:-4010})
#   REDIS_CONTAINER  (default gridtokenx-redis)
#   GATEWAY_SECRET   (default gridtokenx-gateway-secret-2025)
#   DEFAULT_PASS     (default TestPass123!)
#   LAT_E7 / LONG_E7 (default Bangkok)

# Defaults shared by both commands.
_pm_defaults() {
    PM_BASE="${IAM_BASE:-http://localhost:${IAM_HTTP_PORT:-4010}}"
    PM_REDIS="${REDIS_CONTAINER:-gridtokenx-redis}"
    PM_PASS="${DEFAULT_PASS:-TestPass123!}"
    PM_GW_SECRET="${GATEWAY_SECRET:-gridtokenx-gateway-secret-2025}"
    PM_LAT="${LAT_E7:-13750000}"
    PM_LONG="${LONG_E7:-100500000}"
}

# Create an on-chain user. Echoes the user_id on stdout; all logs go to stderr
# so callers can capture: uid=$(_pm_create_user prosumer email).
_pm_create_user() {
    local user_type="$1" email="$2"
    local ts; ts=$(date +%s%N)
    local username="meter_user_${ts}"
    [ -z "$email" ] && email="${username}@example.com"

    local gw=(-H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: $PM_GW_SECRET")

    if ! curl -fsS -m 5 "$PM_BASE/health" >/dev/null 2>&1; then
        log_error "IAM service not reachable at $PM_BASE/health" >&2
        return 1
    fi

    log_info "Registering user $username ($user_type)..." >&2
    local reg uid
    reg=$(curl -s -X POST "$PM_BASE/api/v1/auth/register" \
          -H "Content-Type: application/json" \
          -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$PM_PASS\"}")
    uid=$(echo "$reg" | jq -r '.id // .data.id // empty')
    if [ -z "$uid" ]; then
        log_error "register failed: $(echo "$reg" | head -c 200)" >&2
        return 1
    fi
    log_success "registered user_id=$uid" >&2

    curl -s -X GET "$PM_BASE/api/v1/auth/verify?token=verify_${email}" >/dev/null

    local token
    token=$(curl -s -X POST "$PM_BASE/api/v1/auth/login" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"$username\",\"password\":\"$PM_PASS\"}" \
            | jq -r '.access_token // .data.auth.access_token // empty')
    if [ -z "$token" ]; then
        log_error "login failed — cannot link wallet / register on-chain" >&2
        return 1
    fi
    local auth=(-H "Authorization: Bearer $token")

    if command -v solana-keygen >/dev/null 2>&1; then
        local kf; kf=$(mktemp)
        solana-keygen new --no-bip39-passphrase --silent --force --outfile "$kf" >/dev/null 2>&1
        local wallet; wallet=$(solana-keygen pubkey "$kf" 2>/dev/null)
        rm -f "$kf"
        local link
        link=$(curl -s -X POST "$PM_BASE/api/v1/me/wallets" \
               "${gw[@]}" "${auth[@]}" -H "Content-Type: application/json" \
               -d "{\"wallet_address\":\"$wallet\",\"label\":\"Primary\",\"is_primary\":true}")
        if echo "$link" | jq -e '.id' >/dev/null 2>&1; then
            log_success "linked wallet $wallet" >&2
        else
            log_warn "wallet link returned: $(echo "$link" | head -c 160)" >&2
        fi
    else
        log_warn "solana-keygen not found — using verify-time mock wallet; on-chain may reject." >&2
    fi

    local onb status sig
    onb=$(curl -s -X POST "$PM_BASE/api/v1/me/registration" \
          "${gw[@]}" "${auth[@]}" -H "Content-Type: application/json" \
          -d "{\"user_type\":\"$user_type\",\"location\":{\"lat_e7\":$PM_LAT,\"long_e7\":$PM_LONG}}")
    status=$(echo "$onb" | jq -r '.status // "unknown"')
    sig=$(echo "$onb" | jq -r '.transaction_signature // "-"')
    case "$status" in
        processing|registered|success) log_success "on-chain status=$status sig=$sig" >&2 ;;
        *) log_warn "on-chain registration status=$status — user created but not on-chain: $(echo "$onb" | head -c 160)" >&2 ;;
    esac

    echo "$uid"
}

# Map one meter -> user in Redis (the key the settlement engine reads). Logs to stderr.
_pm_map_meter() {
    local meter_id="$1" uid="$2"
    local key="gridtokenx:meters:${meter_id}:user_id"

    if ! docker exec "$PM_REDIS" redis-cli EXISTS "gridtokenx:devices:${meter_id}:pubkey" 2>/dev/null | grep -q '^1$'; then
        log_warn "$meter_id: no signing pubkey (mapping still set)" >&2
    fi

    if ! docker exec "$PM_REDIS" redis-cli SET "$key" "$uid" >/dev/null 2>&1; then
        log_error "$meter_id: redis SET failed (container '$PM_REDIS' up?)" >&2
        return 1
    fi
    local rb; rb=$(docker exec "$PM_REDIS" redis-cli GET "$key" 2>/dev/null)
    if [ "$rb" != "$uid" ]; then
        log_error "$meter_id: map verify failed (got '$rb')" >&2
        return 1
    fi
    log_success "mapped $key = $uid" >&2
}

# ── Single meter ─────────────────────────────────────────────────────────────
cmd_provision_meter() {
    show_banner
    local meter_id="${1:-}" user_type="${2:-prosumer}" email="${3:-}"
    if [ -z "$meter_id" ]; then
        log_error "meter_id required.  Usage: $0 provision-meter <meter_id> [user_type] [email]"
        return 1
    fi
    command -v jq   >/dev/null 2>&1 || { log_error "jq required";   return 1; }
    command -v curl >/dev/null 2>&1 || { log_error "curl required"; return 1; }
    _pm_defaults

    local uid="${USER_ID:-}"
    if [ -n "$uid" ]; then
        log_info "Mapping $meter_id to existing user_id=$uid"
    else
        uid=$(_pm_create_user "$user_type" "$email") || return 1
    fi
    _pm_map_meter "$meter_id" "$uid" || return 1
    log_success "Meter $meter_id provisioned -> user $uid."
}

# ── Many meters, one shared user ─────────────────────────────────────────────
cmd_provision_meters() {
    show_banner
    local src="${1:-}" user_type="${2:-prosumer}"
    if [ -z "$src" ]; then
        log_error "file required.  Usage: $0 provision-meters <file|-> [user_type]   (one meter_id per line, '-' = stdin)"
        return 1
    fi
    command -v jq   >/dev/null 2>&1 || { log_error "jq required";   return 1; }
    command -v curl >/dev/null 2>&1 || { log_error "curl required"; return 1; }
    _pm_defaults

    # Read + sanitize meter ids (skip blanks/comments).
    local meters=()
    local line
    if [ "$src" == "-" ]; then
        while IFS= read -r line; do line="${line//[$' \t\r']/}"; [ -z "$line" ] && continue; case "$line" in \#*) continue;; esac; meters+=("$line"); done
    else
        [ -f "$src" ] || { log_error "file not found: $src"; return 1; }
        while IFS= read -r line; do line="${line//[$' \t\r']/}"; [ -z "$line" ] && continue; case "$line" in \#*) continue;; esac; meters+=("$line"); done < "$src"
    fi
    if [ "${#meters[@]}" -eq 0 ]; then
        log_error "no meter ids found in $src"
        return 1
    fi
    log_info "Mapping ${#meters[@]} meters to ONE shared user."

    local uid="${USER_ID:-}"
    if [ -n "$uid" ]; then
        log_info "Using existing user_id=$uid"
    else
        uid=$(_pm_create_user "$user_type" "") || return 1
    fi

    local ok=0 fail=0 m
    for m in "${meters[@]}"; do
        if _pm_map_meter "$m" "$uid"; then ((ok++)); else ((fail++)); fi
    done
    log_success "Mapped $ok/${#meters[@]} meters -> user $uid  (failed=$fail)"
    [ "$fail" -eq 0 ]
}
