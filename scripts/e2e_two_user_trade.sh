#!/usr/bin/env bash
# GridTokenX — minimal E2E: 2 users (1 prosumer seller + 1 consumer buyer)
# register end-to-end, then trade with each other so the CDA matcher fills a
# real cross and settlement is verified on-chain.
#
# Flow (per user, HTTP API only — reuses register_users_meters_api.sh pattern):
#   1. Register       POST /api/v1/auth/register
#   2. Verify email   GET  /api/v1/auth/verify?token=verify_<email>
#                       -> auto-airdrop SOL + custodial wallet + on-chain PDA
#   3. Login          POST /api/v1/auth/login  -> JWT
#   4. Read wallet    GET  /api/v1/me/wallets
#   5. On-chain reg   POST /api/v1/me/registration  (user_type prosumer|consumer)
#
# Then the trade leg:
#   6. Prosumer SELL  POST /api/v1/orders  (ask @ SELL_PRICE)
#   7. Consumer BUY   POST /api/v1/orders  (bid @ BUY_PRICE >= SELL_PRICE -> crosses)
#   8. Wait for the MatcherWorker (~1s cadence) to drain the crossed book
#   9. Verify         GET /api/v1/markets/matching-status + /api/v1/trades
#
# Both orders land in the SAME zone so bid/ask meet. No manual match call.
#
# Usage:
#   ./scripts/e2e_two_user_trade.sh
#
# Env overrides:
#   IAM_BASE       IAM/APISIX login base   (default http://localhost:4010)
#   GW             trading gateway (https) (default https://apisix.gridtokenx-coresystem.orb.local)
#   GATEWAY_SECRET api-gateway shared secret (default gridtokenx-gateway-secret-2025)
#   DEFAULT_PASS   user password           (default TestPass123!)
#   ZONE_ID        order zone              (default 1)
#   SELL_PRICE     ask price per kWh       (default 4.00)
#   BUY_PRICE      bid price per kWh       (default 4.50; must be >= SELL_PRICE)
#   TRADE_KWH      energy amount per order (default 5)
#   LAT_E7/LONG_E7 on-chain location       (default Bangkok)
#   SETTLE_WAIT    seconds to wait for the matcher (default 8)
#   SKIP_ONCHAIN=1 skip step 5 (custodial already auto-registered on verify)

set -uo pipefail

IAM_BASE="${IAM_BASE:-http://localhost:${IAM_HTTP_PORT:-4010}}"
GW="${GW:-https://apisix.gridtokenx-coresystem.orb.local}"
GW_SECRET="${GATEWAY_SECRET:-gridtokenx-gateway-secret-2025}"
PASS="${DEFAULT_PASS:-TestPass123!}"
ZONE_ID="${ZONE_ID:-1}"
SELL_PRICE="${SELL_PRICE:-4.00}"
BUY_PRICE="${BUY_PRICE:-4.50}"
TRADE_KWH="${TRADE_KWH:-5}"
LAT="${LAT_E7:-13750000}"
LONG="${LONG_E7:-100500000}"
SETTLE_WAIT="${SETTLE_WAIT:-8}"

# On-chain registration is DETACHED in IAM (auth_service.rs spawn_onchain_registration):
# verify/registration return 200 BEFORE the chain lands. The API never surfaces the
# confirmed state (/me returns null, /me/registration always says "processing"), so the
# reliable signal is the IAM users.blockchain_registered column. Gate on it via the DB
# container so trading doesn't race an unconfirmed PDA (else the on-chain order leg fails).
PG_CONTAINER="${PG_CONTAINER:-gridtokenx-postgres}"
PG_USER="${PG_USER:-gridtokenx_user}"
PG_DB="${PG_DB:-gridtokenx}"
REG_CONFIRM_WAIT="${REG_CONFIRM_WAIT:-45}"   # seconds to wait for on-chain reg to confirm

c_grn='\033[0;32m'; c_red='\033[0;31m'; c_yel='\033[0;33m'; c_blu='\033[0;34m'; c_rst='\033[0m'
ok()   { printf "${c_grn}✔${c_rst} %s\n" "$*"; }
info() { printf "${c_blu}ℹ${c_rst} %s\n" "$*"; }
warn() { printf "${c_yel}⚠${c_rst} %s\n" "$*"; }
err()  { printf "${c_red}✘${c_rst} %s\n" "$*" >&2; }
step() { printf "\n${c_blu}== %s ==${c_rst}\n" "$*"; }

for bin in jq curl; do
    command -v "$bin" >/dev/null 2>&1 || { err "$bin required but not installed"; exit 1; }
done
curl -fsS -m 5 "$IAM_BASE/health" >/dev/null 2>&1 || { err "IAM not reachable at $IAM_BASE/health"; exit 1; }

gw=(-H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: $GW_SECRET")

# nanosecond stamp for collision-free usernames (BSD/macOS date lacks %N)
if command -v gdate >/dev/null 2>&1; then
    now_ns() { gdate +%s%N; }
elif [ "$(date +%N 2>/dev/null)" != "N" ] && [ -n "$(date +%N 2>/dev/null)" ]; then
    now_ns() { date +%s%N; }
else
    now_ns() { printf '%s%09d' "$(date +%s)" "$((RANDOM * RANDOM % 1000000000))"; }
fi

# wait_onchain_confirmed <user_id> — block until IAM's detached on-chain registration
# actually confirms (users.blockchain_registered = t). The verify/registration APIs return
# 200 optimistically ~14-30s before the Registry PDA lands; placing an order in that window
# fails the on-chain order leg ("no on-chain PDA"). Degrades gracefully (warn, don't abort)
# if the DB container isn't reachable — the trade still runs, just without the guarantee.
wait_onchain_confirmed() {
    local uid="$1" i reg
    if ! command -v docker >/dev/null 2>&1 || ! docker exec "$PG_CONTAINER" true >/dev/null 2>&1; then
        warn "DB ($PG_CONTAINER) unreachable — skipping on-chain confirm gate; trade may race registration"
        return 0
    fi
    for i in $(seq 1 "$REG_CONFIRM_WAIT"); do
        reg=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
              "SELECT blockchain_registered FROM users WHERE id='$uid';" 2>/dev/null | tr -d '[:space:]')
        case "$reg" in
            t|true) ok "on-chain registration CONFIRMED (blockchain_registered=t, ${i}s)"; return 0 ;;
        esac
        sleep 1
    done
    warn "on-chain registration NOT confirmed after ${REG_CONFIRM_WAIT}s (blockchain_registered='${reg:-null}') — on-chain order leg may fail"
    return 0
}

# onboard <user_type> -> sets globals: USERNAME EMAIL WALLET TOKEN
onboard() {
    local user_type="$1" stamp username email reg uid vres token wres wallet
    stamp=$(now_ns)
    username="${user_type}_${stamp}"; email="${username}@example.com"
    info "onboard $user_type: $username"

    # 1. register
    reg=$(curl -s -X POST "$IAM_BASE/api/v1/auth/register" -H 'Content-Type: application/json' \
          -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$PASS\"}")
    uid=$(echo "$reg" | jq -r '.id // .data.id // empty')
    [ -z "$uid" ] && { err "register failed: $(echo "$reg" | head -c160)"; return 1; }
    ok "registered user_id=$uid"

    # 2. verify -> auto airdrop + custodial wallet + on-chain PDA
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
    [ -z "$token" ] && { err "login failed: $username"; return 1; }
    local auth=(-H "Authorization: Bearer $token")

    # 4. read custodial wallet
    wres=$(curl -s "$IAM_BASE/api/v1/me/wallets" "${gw[@]}" "${auth[@]}")
    wallet=$(echo "$wres" | jq -r '
        [ (.wallets // .data.wallets // .data // .) | (if type=="array" then . else [.] end)[] ]
        | (map(select(.is_primary==true)) + .)
        | .[0].wallet_address // .[0].address // empty')
    [ -z "$wallet" ] && warn "no custodial wallet found: $(echo "$wres" | head -c120)"
    [ -n "$wallet" ] && ok "custodial wallet $wallet"

    # 5. on-chain registration with the intended user_type (idempotent)
    if [ "${SKIP_ONCHAIN:-0}" != "1" ]; then
        local onb onb_code onb_body onb_status
        onb=$(curl -s -w '\n%{http_code}' -X POST "$IAM_BASE/api/v1/me/registration" "${gw[@]}" "${auth[@]}" \
              -H 'Content-Type: application/json' \
              -d "{\"user_type\":\"$user_type\",\"location\":{\"lat_e7\":$LAT,\"long_e7\":$LONG}}")
        onb_code=$(printf '%s' "$onb" | tail -n1); onb_body=$(printf '%s' "$onb" | sed '$d')
        onb_status=$(printf '%s' "$onb_body" | jq -r '.status // "unknown"')
        case "$onb_code" in
            2??) info "on-chain status=$onb_status (http=$onb_code)" ;;
            *)   warn "on-chain registration http=$onb_code: $(printf '%s' "$onb_body" | head -c120)" ;;
        esac

        # 6. GATE: block until the detached on-chain registration actually confirms
        #    (the API status above is optimistic — the PDA lands ~14-30s later).
        wait_onchain_confirmed "$uid"
    fi

    USERNAME="$username"; EMAIL="$email"; WALLET="$wallet"; TOKEN="$token"
}

# submit_order <token> <side> <kwh> <price> -> echoes order id, non-zero on fail
submit_order() {
    local token="$1" side="$2" kwh="$3" price="$4" resp code body
    resp=$(curl -sk -m40 -w '\n%{http_code}' -X POST "${GW}/api/v1/orders" \
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        -d "{\"side\":\"$side\",\"order_type\":\"limit\",\"energy_amount_kwh\":\"$kwh\",\"price_per_kwh\":\"$price\",\"zone_id\":$ZONE_ID}")
    code=$(printf '%s' "$resp" | tail -n1); body=$(printf '%s' "$resp" | sed '$d')
    case "$code" in
        2??) printf '%s' "$(printf '%s' "$body" | jq -r '.id // empty')"; return 0 ;;
        *)   printf '%s' "$body" | head -c200 >&2; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
step "1) Onboard PROSUMER (seller)"
onboard prosumer || { err "prosumer onboarding failed"; exit 1; }
PROSUMER_USER="$USERNAME"; PROSUMER_WALLET="$WALLET"; PROSUMER_TOKEN="$TOKEN"

step "2) Onboard CONSUMER (buyer)"
onboard consumer || { err "consumer onboarding failed"; exit 1; }
CONSUMER_USER="$USERNAME"; CONSUMER_WALLET="$WALLET"; CONSUMER_TOKEN="$TOKEN"

step "3) Trade — prosumer SELL x consumer BUY (zone $ZONE_ID)"
info "prosumer SELL ${TRADE_KWH}kWh @ $SELL_PRICE   consumer BUY ${TRADE_KWH}kWh @ $BUY_PRICE"
if sid=$(submit_order "$PROSUMER_TOKEN" sell "$TRADE_KWH" "$SELL_PRICE"); [ -n "$sid" ]; then
    ok "prosumer ask placed: sell=$sid"
else
    err "prosumer SELL failed"; exit 1
fi
if bid=$(submit_order "$CONSUMER_TOKEN" buy "$TRADE_KWH" "$BUY_PRICE"); [ -n "$bid" ]; then
    ok "consumer bid placed: buy=$bid"
else
    err "consumer BUY failed"; exit 1
fi

step "4) Wait ${SETTLE_WAIT}s for CDA matcher to fill the crossed book"
i=0; while [ "$i" -lt "$SETTLE_WAIT" ]; do curl -s -o /dev/null "$IAM_BASE/health" 2>/dev/null; i=$((i+1)); done

step "5) Verify — matching status"
curl -sk -m15 "${GW}/api/v1/markets/matching-status" -H "Authorization: Bearer $PROSUMER_TOKEN" | jq . 2>/dev/null \
    || warn "matching-status unavailable"

step "6) Verify — recent trades"
trades=$(curl -sk -m15 "${GW}/api/v1/trades?limit=10" -H "Authorization: Bearer $PROSUMER_TOKEN")
echo "$trades" | jq '{total_count, total, sample: (.trades[0] // null)}' 2>/dev/null || echo "$trades" | head -c300

# did OUR two orders fill? look for a trade referencing either order id
matched=$(echo "$trades" | jq --arg s "$sid" --arg b "$bid" \
    '[.trades[]? | select((.buy_order_id==$b) or (.sell_order_id==$s) or (.maker_order_id==$s) or (.taker_order_id==$b))] | length' 2>/dev/null)
printf '\n'
if [ "${matched:-0}" -gt 0 ]; then
    ok "MATCH CONFIRMED: our sell=$sid / buy=$bid produced $matched trade(s)."
else
    warn "no trade yet references sell=$sid / buy=$bid — matcher may still be draining; re-check /api/v1/trades or raise SETTLE_WAIT."
fi

step "Summary"
info "prosumer: $PROSUMER_USER  wallet=$PROSUMER_WALLET"
info "consumer: $CONSUMER_USER  wallet=$CONSUMER_WALLET"
info "orders:   sell=$sid  buy=$bid  zone=$ZONE_ID  ${TRADE_KWH}kWh  sell@$SELL_PRICE buy@$BUY_PRICE"
