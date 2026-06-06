#!/usr/bin/env bash
# GridTokenX E2E — HTTP helpers (curl + jq). Source after env.sh + assert.sh.
# Conventions mirror scripts/production-e2e.sh.

# http_json <METHOD> <URL> [json_body] [extra curl args...]
# Echoes response body. Status persisted to $E2E_STATUS_FILE — read it with `hs` (not
# $HTTP_STATUS), because callers wrap this in `$(...)` and the subshell var is lost.
http_json() {
    local method="$1" url="$2" body="${3:-}"; shift 3 2>/dev/null || shift $#
    local tmp; tmp=$(mktemp)
    local args=(-s -o "$tmp" -w '%{http_code}' -X "$method" -H "Content-Type: application/json")
    [ -n "$body" ] && args+=(-d "$body")
    args+=("$@")
    HTTP_STATUS=$(curl "${args[@]}" "$url")
    printf '%s' "$HTTP_STATUS" > "${E2E_STATUS_FILE:-/tmp/e2e_http_status}"
    cat "$tmp"; rm -f "$tmp"
}

# hs — last HTTP status from http_json, surviving the $() subshell it ran in.
hs() { cat "${E2E_STATUS_FILE:-/tmp/e2e_http_status}" 2>/dev/null || echo "000"; }

# auth_json <METHOD> <URL> <JWT> [json_body] — adds Bearer + gateway headers.
auth_json() {
    local method="$1" url="$2" jwt="$3" body="${4:-}"
    http_json "$method" "$url" "$body" \
        -H "Authorization: Bearer $jwt" "${GATEWAY_HEADERS[@]}"
}

# Routes (IAM direct :4010) — confirmed in bin/iam-service/src/startup.rs.
# register_user <username> <email> — echoes user id (.id). Sets REG_RESP, REG_USER_ID.
# NOTE: REG_RESP/REG_USER_ID only survive if this is NOT called in a $() subshell.
register_user() {
    local username="$1" email="$2"
    REG_RESP=$(http_json POST "$IAM_URL/api/v1/auth/register" \
        "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$E2E_PASSWORD\",\"first_name\":\"E2E\",\"last_name\":\"Tester\"}")
    REG_USER_ID=$(echo "$REG_RESP" | jq -r '.id // empty')
    echo "$REG_USER_ID"
}

# verify_user <user_id> — pulls real token from DB, hits /auth/verify.
# Echoes JWT (.auth.access_token). Sets VERIFY_RESP, WALLET_ADDRESS. Needs lib/db.sh sourced.
verify_user() {
    local uid="$1" token
    token=$(db_verify_token "$uid")
    [ -n "$token" ] || { echo ""; return 1; }
    VERIFY_RESP=$(http_json GET "$IAM_URL/api/v1/auth/verify" "" --get --data-urlencode "token=$token")
    WALLET_ADDRESS=$(echo "$VERIFY_RESP" | jq -r '.wallet_address // empty')
    E2E_JWT=$(echo "$VERIFY_RESP" | jq -r '.auth.access_token // empty')
    echo "$E2E_JWT"
}

# login <username> <password> — echoes JWT or empty. Sets LOGIN_RESP.
login() {
    LOGIN_RESP=$(http_json POST "$IAM_URL/api/v1/auth/login" \
        "{\"username\":\"$1\",\"password\":\"$2\"}")
    echo "$LOGIN_RESP" | jq -r '.auth.access_token // .access_token // empty'
}

# onboard_user <jwt> <user_type> — POST /users/me/onchain-profile. Echoes body, sets HTTP_STATUS.
onboard_user() {
    auth_json POST "$IAM_URL/api/v1/users/me/onchain-profile" "$1" \
        "{\"user_type\":\"${2:-prosumer}\",\"location\":{\"lat_e7\":13756300,\"long_e7\":100501800}}"
}

# link_wallet <jwt> <wallet_address> — POST /users/me/wallets. Echoes body, sets HTTP_STATUS.
link_wallet() {
    auth_json POST "$IAM_URL/api/v1/users/me/wallets" "$1" \
        "{\"wallet_address\":\"$2\",\"label\":\"E2E Secondary\",\"is_primary\":false}"
}

# get_me <jwt> — GET /users/me. Echoes body, sets HTTP_STATUS.
get_me() { auth_json GET "$IAM_URL/api/v1/users/me" "$1"; }

# new_user — full register+verify, echoes JWT.
# Sets E2E_USERNAME, E2E_EMAIL, E2E_USER_ID, WALLET_ADDRESS, REG_RESP, VERIFY_RESP, E2E_JWT.
# IMPORTANT: call directly (`new_user; JWT="$E2E_JWT"`), NOT `JWT=$(new_user)`. The latter
# runs this in a subshell so all the side-effect globals above are lost in the caller.
new_user() {
    export E2E_USERNAME="e2e_${E2E_RUN_ID}_$RANDOM"
    export E2E_EMAIL="${E2E_USERNAME}@grx.test"
    register_user "$E2E_USERNAME" "$E2E_EMAIL" >/dev/null   # sets REG_RESP, REG_USER_ID here
    export E2E_USER_ID="${REG_USER_ID:-}"
    [ -n "$E2E_USER_ID" ] || die "register failed for $E2E_USERNAME: ${REG_RESP:-}"
    verify_user "$E2E_USER_ID" >/dev/null                   # sets VERIFY_RESP, WALLET_ADDRESS, E2E_JWT
    export E2E_JWT WALLET_ADDRESS REG_RESP VERIFY_RESP
    echo "$E2E_JWT"
}
