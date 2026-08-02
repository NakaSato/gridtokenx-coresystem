#!/usr/bin/env bash
# GridTokenX — full E2E: 2 users (1 prosumer seller + 1 consumer buyer)
# register end-to-end, add a meter to each account, then trade with each
# other so the CDA matcher fills a real cross and settlement is verified
# on-chain.
#
# Flow (per user, HTTP API only — reuses register_users_meters_api.sh pattern):
#   1. Register       POST /api/v1/auth/register
#   2. Verify email   GET  /api/v1/auth/verify?token=verify_<email>
#                       -> auto-airdrop SOL + custodial wallet + on-chain PDA
#   3. Login          POST /api/v1/auth/login  -> JWT
#   4. Read wallet    GET  /api/v1/me/wallets
#   5. On-chain reg   POST /api/v1/me/registration  (user_type prosumer|consumer)
#   6. Add meter      POST /api/v1/meters (meter-service, JWT) -> real meter id (UUID)
#   6b. Wire telemetry serial = a REAL device id read from the smartmeter-simulator's
#       own API (GET $SIM_REST_BASE/api/v1/meters — a has_solar=true meter for the
#       prosumer, has_solar=false for the consumer), then re-point the Aggregator
#       Bridge's Redis attribution (device pubkey + owner + wallet) at this run's
#       user, so telemetry the simulator ALREADY emits for that meter attributes to
#       our IAM user (mirrors scripts/register_users_meters.sh steps 6-7).
#
# Then the trade leg:
#   7. Prosumer SELL  POST /api/v1/orders  (ask @ SELL_PRICE)
#   8. Consumer BUY   POST /api/v1/orders  (bid @ BUY_PRICE >= SELL_PRICE -> crosses)
#   9. Wait for the MatcherWorker (~1s cadence) to drain the crossed book
#  10. Verify         GET /api/v1/markets/matching-status + /api/v1/trades
#
# Both orders land in the SAME zone so bid/ask meet. No manual match call.
#
# Usage:
#   ./scripts/e2e_two_user_trade.sh
#
# Env overrides:
#   IAM_BASE        IAM/APISIX login base   (default http://localhost:4010)
#   METER_BASE      meter-service base      (default http://localhost:4062)
#   SIM_REST_BASE   sim's own REST API      (default http://localhost:8082)
#   SIM_CONTAINER   sim container (Ed25519 signing derivation) (default gridtokenx-smartmeter-simulator)
#   REDIS_CONTAINER redis container (bridge device registry)   (default gridtokenx-redis)
#   KEY_SECRET      sim's per-meter Ed25519 seed secret (default gridtokenx-sim; must match
#                   the sim's own MeterKey default — see transport/aggregator_bridge.py)
#   SIM_CANDIDATE_POOL  how many real sim meter ids to try per side before falling back
#                       to an invented serial (default 25; a sim meter is one-owner, so
#                       ids a prior run already claimed 409 and are skipped)
#   GW              trading gateway (default http://localhost:4001 — APISIX published port)
#   GATEWAY_SECRET  api-gateway shared secret (default gridtokenx-gateway-secret-2025)
#   DEFAULT_PASS    user password           (default TestPass123!)
#   ZONE_ID         order zone              (default 1)
#   SELL_PRICE      ask price per kWh       (default 4.00)
#   BUY_PRICE       bid price per kWh       (default 4.50; must be >= SELL_PRICE)
#   TRADE_KWH       energy amount per order (default 5)
#   LAT_E7/LONG_E7  on-chain location       (default Bangkok)
#   SETTLE_WAIT     max seconds to poll for the P2P match (default 30)
#   SETTLE_TX_WAIT  max seconds to poll for the on-chain settlement tx (default 60)
#   PROSUMER_USERNAME / CONSUMER_USERNAME (+ _PASSWORD, _EMAIL)
#                   pin one side to a named account instead of a generated one;
#                   an existing account is reused via login (register conflict is
#                   not an error). Unset = generated, as before.
#
# NOTE ON ZONES: only zones with an on-chain zone config can settle. Ordering in an
# uninitialized zone still returns 200 and still MATCHES off-chain, but on-chain
# placement fails with Custom(3007), the order gets no PDA, and settlement ends
# permanently_failed. Step 7 detects exactly that. See scripts/init-zones.sh.
#   SKIP_ONCHAIN=1  skip step 5 (custodial already auto-registered on verify)
#   SKIP_METER=1    skip step 6 (meter registration + telemetry wiring)
#   WIRE_TELEMETRY=0  skip step 6b only — meter still registered, but with an
#                     invented GRID-<stamp> serial instead of a real sim device id

set -uo pipefail

IAM_BASE="${IAM_BASE:-http://localhost:${IAM_HTTP_PORT:-4010}}"
METER_BASE="${METER_BASE:-http://localhost:${METER_SERVICE_PORT:-4062}}"
# 12010 is the HOST port compose publishes for the sim (container-side 8082) —
# `docker port gridtokenx-smartmeter-simulator`. The old 8082 default is the
# in-container port and is not reachable from the host.
SIM_REST_BASE="${SIM_REST_BASE:-http://localhost:${SMARTMETER_PORT:-12010}}"
SIM_CONTAINER="${SIM_CONTAINER:-gridtokenx-smartmeter-simulator}"
REDIS_CONTAINER="${REDIS_CONTAINER:-gridtokenx-redis}"
KEY_SECRET="${KEY_SECRET:-gridtokenx-sim}"
WIRE_TELEMETRY="${WIRE_TELEMETRY:-1}"
# APISIX on its published HTTP port, not the .orb.local hostname: OrbStack's
# domain proxy stopped landing on a serving container port after a recreate, so
# that host 404'd every path (including auth-exempt /health) while the real
# listener on :4001 served routes correctly.
GW="${GW:-http://localhost:4001}"
GW_SECRET="${GATEWAY_SECRET:-gridtokenx-gateway-secret-2025}"
PASS="${DEFAULT_PASS:-TestPass123!}"
ZONE_ID="${ZONE_ID:-1}"
SELL_PRICE="${SELL_PRICE:-4.00}"
BUY_PRICE="${BUY_PRICE:-4.50}"
TRADE_KWH="${TRADE_KWH:-5}"
LAT="${LAT_E7:-13750000}"
LONG="${LONG_E7:-100500000}"
# Now a real timeout (poll + sleep), not a spin count. Matcher runs ~1s; the
# settlement batch worker claims on a ~10s cadence, so SETTLE_TX_WAIT must clear
# at least one batch tick plus confirmation.
SETTLE_WAIT="${SETTLE_WAIT:-30}"
SETTLE_TX_WAIT="${SETTLE_TX_WAIT:-60}"

# On-chain registration is DETACHED in IAM (auth_service.rs spawn_onchain_registration):
# verify/registration return 200 BEFORE the chain lands. The API never surfaces the
# confirmed state (/me returns null, /me/registration always says "processing"), so the
# reliable signal is the IAM users.blockchain_registered column. Gate on it via the DB
# container so trading doesn't race an unconfirmed PDA (else the on-chain order leg fails).
PG_CONTAINER="${PG_CONTAINER:-gridtokenx-postgres}"
PG_USER="${PG_USER:-gridtokenx_user}"
# IAM's `users` table moved to gridtokenx_iam in the DB-per-service split. Pointing
# this at the shared gridtokenx DB makes the query below error every time, so the
# confirm gate below degrades to a 45s no-op and the order leg races the PDA.
PG_DB="${PG_DB:-gridtokenx_iam}"
# Settlements live in the trading service's own DB (step 7 reads transaction_hash).
PG_TRADING_DB="${PG_TRADING_DB:-gridtokenx_trading}"
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
[ "${SKIP_METER:-0}" = "1" ] || curl -fsS -m 5 "$METER_BASE/health" >/dev/null 2>&1 || { err "meter-service not reachable at $METER_BASE/health (set METER_BASE / METER_SERVICE_PORT, or SKIP_METER=1)"; exit 1; }
if [ "${SKIP_METER:-0}" != "1" ] && [ "$WIRE_TELEMETRY" = "1" ]; then
    command -v docker >/dev/null 2>&1 || { err "docker required for telemetry wiring (or set WIRE_TELEMETRY=0)"; exit 1; }
    curl -fsS -m 5 "$SIM_REST_BASE/api/v1/quality/health" >/dev/null 2>&1 || { err "sim REST not reachable at $SIM_REST_BASE (set SIM_REST_BASE / SMARTMETER_PORT, or WIRE_TELEMETRY=0)"; exit 1; }
    docker exec "$SIM_CONTAINER" true >/dev/null 2>&1 || { err "sim container '$SIM_CONTAINER' not running (needed for Ed25519 signing derivation). Set SIM_CONTAINER or WIRE_TELEMETRY=0."; exit 1; }
    docker exec "$REDIS_CONTAINER" redis-cli PING 2>/dev/null | grep -q PONG || { err "redis container '$REDIS_CONTAINER' not reachable. Set REDIS_CONTAINER or WIRE_TELEMETRY=0."; exit 1; }
fi

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

# pick_sim_meters -> sets globals PROSUMER_SIM_CANDIDATES / CONSUMER_SIM_CANDIDATES to
# space-separated pools of REAL device ids read from the simulator's own API
# (has_solar=true for the generation-capable prosumer, has_solar=false for the
# consumer). A meter-service meter is one-owner: a real sim id used by a PRIOR run
# is already registered, so onboard() retries down this pool until one is free
# (SIM_CANDIDATE_POOL controls how many candidates to fetch, default 25).
pick_sim_meters() {
    PROSUMER_SIM_CANDIDATES=""; CONSUMER_SIM_CANDIDATES=""
    [ "$WIRE_TELEMETRY" = "1" ] || return 0
    local list n="${SIM_CANDIDATE_POOL:-25}"
    list=$(curl -s -m10 "$SIM_REST_BASE/api/v1/meters?limit=2000")
    PROSUMER_SIM_CANDIDATES=$(echo "$list" | jq -r --argjson n "$n" \
        '[.meters[] | select(.has_solar==true) | .meter_id][0:$n] | join(" ")')
    CONSUMER_SIM_CANDIDATES=$(echo "$list" | jq -r --argjson n "$n" \
        '[.meters[] | select(.has_solar==false) | .meter_id][0:$n] | join(" ")')
    if [ -n "$PROSUMER_SIM_CANDIDATES" ]; then
        ok "sim prosumer candidates (has_solar): $(echo "$PROSUMER_SIM_CANDIDATES" | wc -w | tr -d ' ')"
    else
        warn "no solar-capable sim meter found — prosumer meter falls back to an invented serial"
    fi
    if [ -n "$CONSUMER_SIM_CANDIDATES" ]; then
        ok "sim consumer candidates: $(echo "$CONSUMER_SIM_CANDIDATES" | wc -w | tr -d ' ')"
    else
        warn "no consumer-type sim meter found — consumer meter falls back to an invented serial"
    fi
}

# create_sim_meter <user_type> -> echoes a freshly-minted REAL sim meter id (or
# empty on failure). Used when the static fleet's candidate pool is exhausted
# (every existing meter already claimed by a prior test run) — mints a brand-new
# device into the running sim engine via its own POST /api/v1/meters, so the sim
# actually generates + emits telemetry for it from the next tick on. Additive
# only: never touches or reassigns an existing meter.
create_sim_meter() {
    local user_type="$1" mtype hasflag resp mid
    if [ "$user_type" = "prosumer" ]; then mtype="Solar_Prosumer"; hasflag=true
    else mtype="Grid_Consumer"; hasflag=false; fi
    # engine.add_meter contends with the sim's tick lock; creation typically takes
    # 7-8s, occasionally more — a short timeout here flakes into a false failure.
    resp=$(curl -s -m25 -X POST "$SIM_REST_BASE/api/v1/meters" -H 'Content-Type: application/json' \
           -d "{\"meter_type\":\"$mtype\",\"lat\":13.75,\"lon\":100.5,\"has_solar\":$hasflag,\"solar_capacity\":5.0}")
    mid=$(echo "$resp" | jq -r '.meter.meter_id // empty')
    if [ -n "$mid" ]; then
        ok "minted fresh sim meter (type=$mtype has_solar=$hasflag): $mid" >&2
    else
        warn "sim meter creation failed: $(echo "$resp" | head -c160)" >&2
    fi
    printf '%s' "$mid"
}

# wire_signing <serial> <user_id> <wallet> — re-derive the sim's own deterministic
# Ed25519 pubkey for this meter (same seed = sha256(KEY_SECRET:serial) the sim uses
# internally, see aggregator_bridge.py MeterKey) and re-point the bridge's Redis
# device registry (pubkey + owner + wallet) at this run's user. The sim keeps
# emitting telemetry for this meter unmodified; only attribution changes.
wire_signing() {
    local serial="$1" uid="$2" wallet="$3" pub
    pub=$(docker exec -e MID="$serial" -e SECRET="$KEY_SECRET" "$SIM_CONTAINER" \
        sh -c 'cat > /tmp/mk.py <<"PY"
import os, hashlib
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
mid=os.environ["MID"]; sec=os.environ["SECRET"]
seed=hashlib.sha256(f"{sec}:{mid}".encode()).digest()
p=Ed25519PrivateKey.from_private_bytes(seed)
print(p.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex())
PY
uv run python /tmp/mk.py' 2>/dev/null | tr -d '[:space:]')
    if [ -z "$pub" ]; then
        warn "meter $serial signing-key derivation failed (telemetry attribution unchanged)"
        return 1
    fi
    docker exec "$REDIS_CONTAINER" redis-cli SET "gridtokenx:devices:${serial}:pubkey" "$pub"    >/dev/null
    docker exec "$REDIS_CONTAINER" redis-cli SET "gridtokenx:meters:${serial}:user_id" "$uid"    >/dev/null
    docker exec "$REDIS_CONTAINER" redis-cli SET "gridtokenx:meters:${serial}:wallet"  "$wallet" >/dev/null
    ok "telemetry attribution wired: sim meter $serial -> user=$uid wallet=$wallet"
}

# onboard <user_type> <sim_candidates (space-separated)> -> sets globals:
# USERNAME EMAIL WALLET TOKEN METER_ID SERIAL
onboard() {
    local user_type="$1" sim_candidates="${2:-}" stamp username email reg uid vres token wres wallet meter_id serial pass ut
    stamp=$(now_ns)
    # Identity override: PROSUMER_USERNAME / CONSUMER_USERNAME (+ _PASSWORD, _EMAIL)
    # pin one side to a named account instead of the collision-free generated one —
    # e.g. a buyer you also want to log into the UI as. Unset = generated, as before.
    ut=$(printf '%s' "$user_type" | tr '[:lower:]' '[:upper:]')
    eval "username=\${${ut}_USERNAME:-}"
    eval "pass=\${${ut}_PASSWORD:-}"
    eval "email=\${${ut}_EMAIL:-}"
    [ -n "$username" ] || username="${user_type}_${stamp}"
    [ -n "$pass" ] || pass="$PASS"
    [ -n "$email" ] || email="${username}@example.com"
    info "onboard $user_type: $username"

    # 1. register
    reg=$(curl -s -X POST "$IAM_BASE/api/v1/auth/register" -H 'Content-Type: application/json' \
          -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$pass\"}")
    uid=$(echo "$reg" | jq -r '.id // .data.id // empty')
    local reused=0
    if [ -z "$uid" ]; then
        # RES_4003 conflict = the account already exists. With a pinned
        # <SIDE>_USERNAME that is the normal case on a re-run, so fall back to
        # logging in and reusing it rather than aborting the whole trade.
        local relog
        relog=$(curl -s -X POST "$IAM_BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
                -d "{\"username\":\"$username\",\"password\":\"$pass\"}")
        uid=$(echo "$relog" | jq -r '.user.id // .data.user.id // empty')
        [ -z "$uid" ] && { err "register failed and login fallback failed: $(echo "$reg" | head -c160)"; return 1; }
        reused=1
        ok "existing account reused user_id=$uid"
    else
        ok "registered user_id=$uid"
    fi

    # 2. verify -> auto airdrop + custodial wallet + on-chain PDA
    # Skipped for a reused account: it is already verified, and the dev
    # verify_<email> token only resolves for the address this run registered.
    if [ "$reused" = "1" ]; then
        info "already verified (existing account) — skipping verify"
    else
        vres=$(curl -s "$IAM_BASE/api/v1/auth/verify?token=verify_${email}")
        if [ "$(echo "$vres" | jq -r '.success // .data.success // empty')" = "true" ]; then
            ok "email verified (auto: airdrop + custodial wallet)"
        else
            warn "verify unconfirmed: $(echo "$vres" | head -c160)"
        fi
    fi

    # 3. login
    token=$(curl -s -X POST "$IAM_BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
            -d "{\"username\":\"$username\",\"password\":\"$pass\"}" \
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

    # 7. add a meter to the account (real meter-service API -> real meter id, UUID).
    #    Try each real sim device id in sim_candidates first (retry: a meter is
    #    one-owner, so ids a PRIOR run already claimed 409 here); if the static
    #    fleet's pool is fully claimed, mint a brand-new sim meter (additive, real
    #    telemetry); only then fall back to an invented GRID-<stamp> serial
    #    (ownership-only, no sim telemetry will ever match it).
    meter_id=""; serial=""
    if [ "${SKIP_METER:-0}" != "1" ]; then
        local fallback="GRID-${user_type}-${stamp}" candidate mreg mid real_match=0 fresh=""
        # Tier 1: retry across the static pool (a meter is one-owner; ids a prior
        # run claimed 409 here and are skipped).
        for candidate in $sim_candidates; do
            mreg=$(curl -s -X POST "$METER_BASE/api/v1/meters" "${auth[@]}" \
                   -H 'Content-Type: application/json' \
                   -d "{\"serial_number\":\"$candidate\",\"meter_type\":\"smart_meter\",\"location\":\"Bangkok\",\"latitude\":13.75,\"longitude\":100.5}")
            mid=$(echo "$mreg" | jq -r '.meter.id // empty')
            if [ -n "$mid" ]; then
                meter_id="$mid"; real_match=1
                serial=$(echo "$mreg" | jq -r '.meter.serial_number // empty'); serial="${serial:-$candidate}"
                break
            fi
        done
        # Tier 2: static pool exhausted — mint one brand-new real sim meter
        # (additive; sim emits real telemetry for it from the next tick).
        if [ -z "$meter_id" ] && [ "$WIRE_TELEMETRY" = "1" ]; then
            fresh=$(create_sim_meter "$user_type")
            if [ -n "$fresh" ]; then
                mreg=$(curl -s -X POST "$METER_BASE/api/v1/meters" "${auth[@]}" \
                       -H 'Content-Type: application/json' \
                       -d "{\"serial_number\":\"$fresh\",\"meter_type\":\"smart_meter\",\"location\":\"Bangkok\",\"latitude\":13.75,\"longitude\":100.5}")
                mid=$(echo "$mreg" | jq -r '.meter.id // empty')
                if [ -n "$mid" ]; then
                    meter_id="$mid"; real_match=1
                    serial=$(echo "$mreg" | jq -r '.meter.serial_number // empty'); serial="${serial:-$fresh}"
                fi
            fi
        fi
        # Tier 3: last resort — invented serial (ownership-only, no sim telemetry
        # will ever match it).
        if [ -z "$meter_id" ]; then
            mreg=$(curl -s -X POST "$METER_BASE/api/v1/meters" "${auth[@]}" \
                   -H 'Content-Type: application/json' \
                   -d "{\"serial_number\":\"$fallback\",\"meter_type\":\"smart_meter\",\"location\":\"Bangkok\",\"latitude\":13.75,\"longitude\":100.5}")
            mid=$(echo "$mreg" | jq -r '.meter.id // empty')
            if [ -n "$mid" ]; then
                meter_id="$mid"
                serial=$(echo "$mreg" | jq -r '.meter.serial_number // empty'); serial="${serial:-$fallback}"
            fi
        fi
        if [ -z "$meter_id" ]; then
            warn "meter registration failed for $username (all sim candidates + fallback exhausted)"
        else
            ok "meter registered id=$meter_id serial=$serial"
            # 7b. re-point sim telemetry attribution at this user (only meaningful
            #     when serial is a REAL sim device id, not the invented fallback).
            if [ "$WIRE_TELEMETRY" = "1" ] && [ "$real_match" = "1" ]; then
                wire_signing "$serial" "$uid" "$wallet"
            fi
        fi
    fi

    USERNAME="$username"; EMAIL="$email"; WALLET="$wallet"; TOKEN="$token"
    METER_ID="$meter_id"; SERIAL="$serial"; USER_ID="$uid"
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
step "0) Pick real sim meters for telemetry attribution"
pick_sim_meters

step "1) Onboard PROSUMER (seller) + add meter"
onboard prosumer "$PROSUMER_SIM_CANDIDATES" || { err "prosumer onboarding failed"; exit 1; }
PROSUMER_USER="$USERNAME"; PROSUMER_WALLET="$WALLET"; PROSUMER_TOKEN="$TOKEN"
PROSUMER_METER_ID="$METER_ID"; PROSUMER_SERIAL="$SERIAL"; PROSUMER_USER_ID="$USER_ID"

step "2) Onboard CONSUMER (buyer) + add meter"
onboard consumer "$CONSUMER_SIM_CANDIDATES" || { err "consumer onboarding failed"; exit 1; }
CONSUMER_USER="$USERNAME"; CONSUMER_WALLET="$WALLET"; CONSUMER_TOKEN="$TOKEN"
CONSUMER_METER_ID="$METER_ID"; CONSUMER_SERIAL="$SERIAL"

# Trading refuses a sell (403) unless the seller owns a VERIFIED meter, and
# registration alone no longer verifies one — it only claims the serial. The real
# proof is signature-verified telemetry (see tests/e2e/97_p2p_prosumer_consumer,
# which drives POST /api/v1/meters/<serial>/verify after pushing signed readings).
# This script sends no telemetry, so it satisfies the meter side of the gate in
# the projection Trading reads, keeping its focus on the trade itself.
if docker exec "$PG_CONTAINER" true >/dev/null 2>&1; then
    docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_TRADING_DB" -c \
      "INSERT INTO meter_read_model (serial_number, meter_id, user_id, zone_id, status, is_verified, updated_at)
       VALUES ('$PROSUMER_SERIAL', gen_random_uuid(), '$PROSUMER_USER_ID', NULL, 'active', true, now())
       ON CONFLICT (serial_number) DO UPDATE SET user_id = EXCLUDED.user_id, is_verified = true, updated_at = now();" \
      >/dev/null 2>&1 \
      && ok "prosumer granted a verified meter (sell gate)" \
      || warn "could not grant a verified meter — the SELL below may be refused 403"
else
    warn "DB unreachable — cannot grant the prosumer a verified meter; the SELL may be refused 403"
fi

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

RESULT=0

step "4) Poll (max ${SETTLE_WAIT}s) for the CDA matcher to fill the crossed book"
# Poll with a REAL sleep. The previous loop spun on curl with no sleep at all, so
# `SETTLE_WAIT=30` elapsed in well under a second and the script reported "no trade
# yet" for trades that landed moments later — a false negative on every run.
matched=0
for _ in $(seq 1 "$SETTLE_WAIT"); do
    trades=$(curl -sk -m15 "${GW}/api/v1/trades?limit=25" -H "Authorization: Bearer $PROSUMER_TOKEN")
    # BOTH ids must appear on the SAME trade. The old check was an `or` across four
    # fields, so it passed when either side merely matched a STRANGER's resting
    # order — it reported "MATCH CONFIRMED" for runs where our two users never
    # traded with each other at all.
    matched=$(echo "$trades" | jq --arg s "$sid" --arg b "$bid" \
        '[.trades[]? | select(.buy_order_id==$b and .sell_order_id==$s)] | length' 2>/dev/null)
    [ "${matched:-0}" -gt 0 ] && break
    sleep 1
done

step "5) Verify — matching status"
curl -sk -m15 "${GW}/api/v1/markets/matching-status" -H "Authorization: Bearer $PROSUMER_TOKEN" | jq . 2>/dev/null \
    || warn "matching-status unavailable"

step "6) Verify — our two orders matched EACH OTHER"
if [ "${matched:-0}" -gt 0 ]; then
    ok "P2P MATCH CONFIRMED: sell=$sid x buy=$bid on the same trade."
else
    err "no trade pairs sell=$sid WITH buy=$bid — each side may have matched foreign liquidity instead."
    warn "for a guaranteed P2P fill, price the ask below every resting ask and the bid below every OTHER resting ask."
    RESULT=1
fi

step "7) Verify — settled ON-CHAIN"
# The trade is only real once the settlement worker lands it on Solana. Everything
# above is off-chain bookkeeping, so a green run without this step proves nothing
# about the chain.
if ! docker exec "$PG_CONTAINER" true >/dev/null 2>&1; then
    warn "DB ($PG_CONTAINER) unreachable — cannot verify on-chain settlement"
else
    stx=""; sstatus=""
    for _ in $(seq 1 "$SETTLE_TX_WAIT"); do
        row=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_TRADING_DB" -tAc \
              "SELECT status||'|'||coalesce(transaction_hash,'') FROM settlements
                WHERE sell_order_id='$sid' AND buy_order_id='$bid' LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
        sstatus="${row%%|*}"; stx="${row#*|}"
        [ -n "$stx" ] && break
        [ "$sstatus" = "permanently_failed" ] && break
        sleep 1
    done
    if [ -n "$stx" ]; then
        ok "SETTLED ON-CHAIN: status=$sstatus tx=$stx"
    elif [ "$sstatus" = "permanently_failed" ]; then
        err "settlement PERMANENTLY FAILED (no on-chain tx). Most common cause: zone $ZONE_ID"
        err "  has no on-chain config, so order placement failed with Custom(3007) and the"
        err "  order carries no PDA. Check: trading-service logs + trading_orders.order_pda."
        RESULT=1
    else
        err "settlement did not reach the chain within ${SETTLE_TX_WAIT}s (status='${sstatus:-none}')"
        RESULT=1
    fi
fi

step "Summary"
info "prosumer: $PROSUMER_USER  wallet=$PROSUMER_WALLET  meter=${PROSUMER_METER_ID:-<skipped>} serial=${PROSUMER_SERIAL:-}"
info "consumer: $CONSUMER_USER  wallet=$CONSUMER_WALLET  meter=${CONSUMER_METER_ID:-<skipped>} serial=${CONSUMER_SERIAL:-}"
info "orders:   sell=$sid  buy=$bid  zone=$ZONE_ID  ${TRADE_KWH}kWh  sell@$SELL_PRICE buy@$BUY_PRICE"
if [ -n "${stx:-}" ]; then
    info "on-chain: $stx"
fi

# Exit non-zero when the P2P match or the on-chain settlement did not happen, so a
# caller (or a loop over rounds) can actually gate on this script.
if [ "$RESULT" -eq 0 ]; then
    ok "🏆 P2P TRADE VERIFIED END-TO-END (matched each other + settled on-chain)"
else
    err "run did NOT fully verify — see the failed step(s) above"
fi
exit "$RESULT"
