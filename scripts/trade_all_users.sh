#!/usr/bin/env bash
# GridTokenX — place BUY + SELL limit orders for every registered user so the
# CDA (Continuous Double Auction) matcher fills them automatically.
#
# Reads the credentials TSV produced by register_users_meters.sh, logs each user
# in for a real IAM JWT, and submits two crossing orders per user:
#   SELL  energy @ SELL_PRICE   (asks)
#   BUY   energy @ BUY_PRICE    (bids, > SELL_PRICE so the book crosses)
# All orders land in the same zone so bids/asks meet. The trading-service
# MatcherWorker drains + matches the book every ~1s — no manual match call.
#
# Usage:
#   ./scripts/trade_all_users.sh [creds_tsv]
#
# Env overrides:
#   GW           trading gateway (default https://apisix.gridtokenx-coresystem.orb.local)
#   IAM_BASE     IAM/APISIX login base (default http://localhost:4010)
#   ZONE_ID      order zone            (default 1)
#   SELL_PRICE   ask price per kWh     (default 4.00)
#   BUY_PRICE    bid price per kWh     (default 4.50; must be >= SELL_PRICE to cross)
#   SELL_KWH     sell energy amount    (default 5)
#   BUY_KWH      buy energy amount     (default 5)
#   SETTLE_WAIT  seconds to wait before reporting matches (default 8)

set -uo pipefail

CREDS="${1:-$(cd "$(dirname "$0")" && pwd)/registered_users_meters.txt}"
GW="${GW:-https://apisix.gridtokenx-coresystem.orb.local}"
IAM_BASE="${IAM_BASE:-http://localhost:${IAM_HTTP_PORT:-4010}}"
ZONE_ID="${ZONE_ID:-1}"
SELL_PRICE="${SELL_PRICE:-4.00}"
BUY_PRICE="${BUY_PRICE:-4.50}"
SELL_KWH="${SELL_KWH:-5}"
BUY_KWH="${BUY_KWH:-5}"
SETTLE_WAIT="${SETTLE_WAIT:-8}"

c_grn='\033[0;32m'; c_red='\033[0;31m'; c_yel='\033[0;33m'; c_blu='\033[0;34m'; c_rst='\033[0m'
ok()   { printf "${c_grn}✔${c_rst} %s\n" "$*"; }
info() { printf "${c_blu}ℹ${c_rst} %s\n" "$*"; }
warn() { printf "${c_yel}⚠${c_rst} %s\n" "$*"; }
err()  { printf "${c_red}✘${c_rst} %s\n" "$*" >&2; }

for bin in jq curl; do
    command -v "$bin" >/dev/null 2>&1 || { err "$bin required"; exit 1; }
done
[ -r "$CREDS" ] || { err "creds file not readable: $CREDS"; exit 1; }

# submit_order <token> <side> <kwh> <price> -> echoes order id, returns non-zero on failure
submit_order() {
    local token="$1" side="$2" kwh="$3" price="$4" resp code
    resp=$(curl -sk -m40 -w '\n%{http_code}' -X POST "${GW}/api/v1/orders" \
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        -d "{\"side\":\"$side\",\"order_type\":\"limit\",\"energy_amount_kwh\":\"$kwh\",\"price_per_kwh\":\"$price\",\"zone_id\":$ZONE_ID}")
    code=$(printf '%s' "$resp" | tail -n1)
    local body; body=$(printf '%s' "$resp" | sed '$d')
    case "$code" in
        2??) printf '%s' "$(printf '%s' "$body" | jq -r '.id // empty')" ; return 0 ;;
        *)   printf '%s' "$body" | head -c160 >&2 ; return 1 ;;
    esac
}

info "Trading gateway: $GW"
info "Creds: $CREDS   zone=$ZONE_ID  sell=$SELL_PRICE x$SELL_KWH  buy=$BUY_PRICE x$BUY_KWH"

users=0 sells=0 buys=0 login_fail=0 order_fail=0
# Skip header row (username\t...). Read TSV columns.
{
    read -r _header
    while IFS=$'\t' read -r username password email wallet serial meter_id user_id; do
        [ -z "$username" ] && continue
        users=$((users+1))
        token=$(curl -s -m15 -X POST "$IAM_BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
                -d "{\"username\":\"$username\",\"password\":\"$password\"}" \
                | jq -r '.access_token // .data.auth.access_token // empty')
        if [ -z "$token" ]; then
            err "login failed: $username"; login_fail=$((login_fail+1)); continue
        fi

        if sid=$(submit_order "$token" sell "$SELL_KWH" "$SELL_PRICE"); [ -n "$sid" ]; then
            sells=$((sells+1)); s_msg="sell=$sid"
        else
            order_fail=$((order_fail+1)); s_msg="sell=FAIL"
        fi
        if bid=$(submit_order "$token" buy "$BUY_KWH" "$BUY_PRICE"); [ -n "$bid" ]; then
            buys=$((buys+1)); b_msg="buy=$bid"
        else
            order_fail=$((order_fail+1)); b_msg="buy=FAIL"
        fi
        ok "$username  $s_msg  $b_msg"
    done
} < "$CREDS"

printf '\n'
ok "Submitted for $users user(s): $sells sells, $buys buys ($login_fail login-fail, $order_fail order-fail)"

# CDA matcher runs every ~1s; give it time to drain the crossed book.
info "Waiting ${SETTLE_WAIT}s for CDA matcher to fill the book…"
i=0; while [ "$i" -lt "$SETTLE_WAIT" ]; do curl -s -o /dev/null http://localhost:4010/health 2>/dev/null; i=$((i+1)); done

# Report using any one user's JWT (trades/matching-status are readable per-user).
first=$(sed -n '2p' "$CREDS")
fu=$(printf '%s' "$first" | cut -f1); fp=$(printf '%s' "$first" | cut -f2)
rtok=$(curl -s -m15 -X POST "$IAM_BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
       -d "{\"username\":\"$fu\",\"password\":\"$fp\"}" | jq -r '.access_token // .data.auth.access_token // empty')

printf '\n== matching-status ==\n'
curl -sk -m15 "${GW}/api/v1/markets/matching-status" -H "Authorization: Bearer $rtok" | jq . 2>/dev/null
printf '\n== recent trades (count) ==\n'
curl -sk -m15 "${GW}/api/v1/trades?limit=5" -H "Authorization: Bearer $rtok" \
  | jq '{total_count, total, sample: (.trades[0] // null)}' 2>/dev/null
