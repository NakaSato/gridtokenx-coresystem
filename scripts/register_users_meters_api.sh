#!/usr/bin/env bash
# GridTokenX — bulk register users + one meter each, HTTP API ONLY.
#
# 100% API: no solana CLI, no redis-cli, no docker exec. Every step is an
# HTTP call to IAM (via APISIX) or the meter-service. Airdrop + wallet are
# handled by the backend automatically at email-verify time:
#   - IAM auto-airdrops SOL on verify when IAM_VERIFY_AIRDROP_SOL>0 (non-prod)
#     (gridtokenx-iam-service auth_service.rs: spawn_verify_airdrop)
#   - IAM auto-provisions a PRIMARY custodial wallet on verify
#     (auth_service.rs: provision_custodial_wallet) and auto-registers it on-chain
#
# Per user, end to end:
#   1. Register     POST /api/v1/auth/register            -> user_id
#   2. Verify email GET  /api/v1/auth/verify?token=verify_<email>
#                     -> confirms account, auto-airdrop, custodial wallet, on-chain PDA
#   3. Login        POST /api/v1/auth/login               -> JWT
#   4. Read wallet  GET  /api/v1/me/wallets               -> custodial primary wallet
#   5. On-chain     POST /api/v1/me/registration          (idempotent; ensures PDA + location)
#   6. Register meter POST /api/v1/meters (meter-service, JWT) -> real meter id (UUID)
#   7. Save         append username,password,email,wallet,serial,meter_id,user_id to TSV
#
# NOTE: this script does NOT wire meter telemetry signing (the Ed25519
# gridtokenx:devices:<serial>:pubkey seed) — no service exposes an API for it.
# Use scripts/register_users_meters.sh if you need signed-telemetry-ready meters.
#
# The bridge self-populates gridtokenx:meters:<serial>:user_id / :wallet from
# Postgres (meters JOIN users), so those Redis maps are NOT needed here.
#
# Usage:
#   ./scripts/register_users_meters_api.sh [count] [output_file]
#     count        number of users to register   (default 80)
#     output_file  credentials TSV               (default scripts/registered_users_meters.txt)
#
# Env overrides:
#   IAM_BASE          IAM/APISIX base URL   (default http://localhost:4010)
#   METER_BASE        meter-service base    (default http://localhost:4062)
#   GATEWAY_SECRET    api-gateway shared secret (default gridtokenx-gateway-secret-2025)
#   DEFAULT_PASS      user password         (default TestPass123!)
#   LAT_E7 / LONG_E7  on-chain location     (default Bangkok)
#   SKIP_ONCHAIN=1    skip step 5 (custodial already auto-registered on verify)

set -uo pipefail

COUNT="${1:-80}"
OUTFILE="${2:-$(cd "$(dirname "$0")" && pwd)/registered_users_meters.txt}"

IAM_BASE="${IAM_BASE:-http://localhost:${IAM_HTTP_PORT:-4010}}"
METER_BASE="${METER_BASE:-http://localhost:${METER_SERVICE_PORT:-4062}}"
GW_SECRET="${GATEWAY_SECRET:-gridtokenx-gateway-secret-2025}"
PASS="${DEFAULT_PASS:-TestPass123!}"
LAT="${LAT_E7:-13750000}"
LONG="${LONG_E7:-100500000}"

c_grn='\033[0;32m'; c_red='\033[0;31m'; c_yel='\033[0;33m'; c_blu='\033[0;34m'; c_rst='\033[0m'
ok()   { printf "${c_grn}✔${c_rst} %s\n" "$*"; }
info() { printf "${c_blu}ℹ${c_rst} %s\n" "$*"; }
warn() { printf "${c_yel}⚠${c_rst} %s\n" "$*"; }
err()  { printf "${c_red}✘${c_rst} %s\n" "$*" >&2; }

# --- preflight (API-only: just jq + curl) ------------------------------------
for bin in jq curl; do
    command -v "$bin" >/dev/null 2>&1 || { err "$bin required but not installed"; exit 1; }
done
if ! curl -fsS -m 5 "$IAM_BASE/health" >/dev/null 2>&1; then
    err "IAM not reachable at $IAM_BASE/health"; exit 1
fi
if ! curl -fsS -m 5 "$METER_BASE/health" >/dev/null 2>&1; then
    err "meter-service not reachable at $METER_BASE/health (set METER_BASE / METER_SERVICE_PORT)"; exit 1
fi

# Nanosecond timestamp for unique usernames. BSD/macOS `date` lacks %N (emits a
# literal "N" -> same-second collisions -> duplicate usernames -> register fails).
if command -v gdate >/dev/null 2>&1; then
    now_ns() { gdate +%s%N; }
elif [ "$(date +%N 2>/dev/null)" != "N" ] && [ -n "$(date +%N 2>/dev/null)" ]; then
    now_ns() { date +%s%N; }
else
    warn "date lacks %N (BSD/macOS); using seconds + random tail for unique stamps"
    now_ns() { printf '%s%09d' "$(date +%s)" "$((RANDOM * RANDOM % 1000000000))"; }
fi

gw=(-H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: $GW_SECRET")

[ -s "$OUTFILE" ] || printf 'username\tpassword\temail\twallet_address\tserial_number\tmeter_id\tuser_id\n' > "$OUTFILE"

info "Registering $COUNT user(s) + one meter each (API-only) -> $IAM_BASE"
info "Credentials: $OUTFILE"

done_n=0 fail_n=0
for i in $(seq 1 "$COUNT"); do
    stamp=$(now_ns)
    username="user_${stamp}" email="user_${stamp}@example.com"
    printf '\n'; info "user $i/$COUNT: $username"

    # 1. register
    reg=$(curl -s -X POST "$IAM_BASE/api/v1/auth/register" -H 'Content-Type: application/json' \
          -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$PASS\"}")
    uid=$(echo "$reg" | jq -r '.id // .data.id // empty')
    [ -z "$uid" ] && { err "register failed: $(echo "$reg" | head -c160)"; fail_n=$((fail_n+1)); continue; }
    ok "registered user_id=$uid"

    # 2. verify email -> confirms account, auto-airdrop + custodial wallet + on-chain PDA
    vres=$(curl -s "$IAM_BASE/api/v1/auth/verify?token=verify_${email}")
    if [ "$(echo "$vres" | jq -r '.success // .data.success // empty')" = "true" ]; then
        ok "email verified (auto: airdrop + custodial wallet)"
    else
        warn "verify unconfirmed: $(echo "$vres" | head -c160)"
    fi

    # 3. login
    token=$(curl -s -X POST "$IAM_BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
            -d "{\"username\":\"$username\",\"password\":\"$PASS\"}" \
            | jq -r '.access_token // .data.auth.access_token // empty')
    [ -z "$token" ] && { err "login failed"; fail_n=$((fail_n+1)); continue; }
    auth=(-H "Authorization: Bearer $token")

    # 4. read the backend-provisioned custodial wallet (primary) — no keygen
    wres=$(curl -s "$IAM_BASE/api/v1/me/wallets" "${gw[@]}" "${auth[@]}")
    wallet=$(echo "$wres" | jq -r '
        [ (.wallets // .data.wallets // .data // .) | (if type=="array" then . else [.] end)[] ]
        | (map(select(.is_primary==true)) + .)
        | .[0].wallet_address // .[0].address // empty')
    if [ -z "$wallet" ]; then
        warn "no custodial wallet found (IAM_VERIFY_AIRDROP_SOL / custodial provisioning enabled?): $(echo "$wres" | head -c160)"
    else
        ok "custodial wallet $wallet"
    fi

    # 5. on-chain registration (idempotent; custodial is auto-registered on verify,
    #    but this ensures the PDA + carries the intended location)
    if [ "${SKIP_ONCHAIN:-0}" != "1" ]; then
        onb=$(curl -s -w '\n%{http_code}' -X POST "$IAM_BASE/api/v1/me/registration" "${gw[@]}" "${auth[@]}" \
              -H 'Content-Type: application/json' \
              -d "{\"user_type\":\"prosumer\",\"location\":{\"lat_e7\":$LAT,\"long_e7\":$LONG}}")
        onb_code=$(printf '%s' "$onb" | tail -n1); onb_body=$(printf '%s' "$onb" | sed '$d')
        onb_status=$(printf '%s' "$onb_body" | jq -r '.status // "unknown"')
        case "$onb_code" in
            2??) info "on-chain status=$onb_status (http=$onb_code)" ;;
            *)   warn "on-chain registration http=$onb_code: $(printf '%s' "$onb_body" | head -c120)" ;;
        esac
    fi

    # 6. register meter via the real meter-service API -> real meter id (UUID)
    serial="GRID-${stamp}"
    mreg=$(curl -s -X POST "$METER_BASE/api/v1/meters" "${auth[@]}" \
           -H 'Content-Type: application/json' \
           -d "{\"serial_number\":\"$serial\",\"meter_type\":\"smart_meter\",\"location\":\"Bangkok\",\"latitude\":13.75,\"longitude\":100.5}")
    meter_id=$(echo "$mreg" | jq -r '.meter.id // empty')
    reg_serial=$(echo "$mreg" | jq -r '.meter.serial_number // empty')
    if [ -z "$meter_id" ]; then
        err "meter register failed: $(echo "$mreg" | head -c200)"; fail_n=$((fail_n+1)); continue
    fi
    serial="${reg_serial:-$serial}"
    ok "meter registered id=$meter_id serial=$serial"

    # 7. save creds
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$username" "$PASS" "$email" "$wallet" "$serial" "$meter_id" "$uid" >> "$OUTFILE"
    done_n=$((done_n+1))
done

printf '\n'
ok "Registered $done_n/$COUNT user(s) with one meter each (API-only)."
[ "$fail_n" -gt 0 ] && warn "$fail_n failed (see log above)."
info "Credentials saved to: $OUTFILE"
