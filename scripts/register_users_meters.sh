#!/usr/bin/env bash
# GridTokenX — bulk register users + attach one meter each (no telemetry/mint).
#
# Per user, end to end:
#   1. Register     POST /api/v1/auth/register            -> user_id
#   2. Verify email GET  /api/v1/auth/verify?token=verify_<email>  (confirm account)
#   3. Login        POST /api/v1/auth/login               -> JWT
#   4. Link wallet  POST /api/v1/me/wallets               (real Solana keypair, primary)
#  4b. Airdrop      solana airdrop <AIRDROP_SOL> <wallet> (validator faucet, dev-only)
#   5. On-chain     POST /api/v1/me/registration          (Registry PDA via Chain Bridge)
#   6. Register meter POST /api/v1/meters (meter-service, JWT) -> REAL meter id (UUID)
#   7. Wire signing  deterministic Ed25519 device key (keyed by serial)
#                     -> gridtokenx:devices:<serial>:pubkey  (signing key)
#                     -> gridtokenx:meters:<serial>:user_id  (owner)
#                     -> gridtokenx:meters:<serial>:wallet   (mint recipient)
#   8. Save         append username,password,email,wallet,serial,meter_id,user_id to TSV
#
# The meter row is a real Postgres record created by the meter-service API
# (POST /api/v1/meters returns {meter:{id,serial_number,...}}); the returned
# `id` is the real meter id. The serial doubles as the telemetry device_id, so
# the Redis maps (signing pubkey + owner + wallet) are keyed by serial to keep
# the downstream Aggregator Bridge ingest/mint path working.
#
# Usage:
#   ./scripts/register_users_meters.sh [count] [output_file]
#     count        number of users to register   (default 80)
#     output_file  credentials TSV               (default scripts/registered_users_meters.txt)
#
# Env overrides:
#   IAM_BASE          IAM/APISIX base URL   (default http://localhost:4010)
#   REDIS_CONTAINER   redis container       (default gridtokenx-redis)
#   SIM_CONTAINER     sim container (Ed25519 signing) (default gridtokenx-smartmeter-simulator)
#   GATEWAY_SECRET    api-gateway shared secret (default gridtokenx-gateway-secret-2025)
#   DEFAULT_PASS      user password         (default TestPass123!)
#   LAT_E7 / LONG_E7  on-chain location     (default Bangkok)
#   RPC_URL           Solana RPC/faucet     (default http://localhost:8899)
#   AIRDROP_SOL       SOL per account       (default 10; 0 disables)
#   SKIP_ONCHAIN=1    skip step 5 (wallet link still runs)
#   SERIALS_FILE      newline-delimited real meter ids to use as serials (overrides
#                     COUNT with the list length). Use the simulator's reference-grid
#                     ids so real sim telemetry attributes to each owner, e.g.:
#                       cd gridtokenx-smartmeter-simulator/backend && python3 -c \
#                         "import csv;h=next(csv.reader(open('data/80_bus_rural_reference_grid/p_load.csv')));\
#                          print('\n'.join(f'ref_lv_bus_{b}' for b in h if b.lower()!='date'))" > real_ids.txt
#                       SERIALS_FILE=real_ids.txt ./scripts/register_users_meters.sh

set -uo pipefail

COUNT="${1:-80}"
OUTFILE="${2:-$(cd "$(dirname "$0")" && pwd)/registered_users_meters.txt}"

# SERIALS_FILE: optional path to a newline-delimited list of REAL meter ids to use as
# each account's meter serial (e.g. the simulator's reference-grid ids `ref_lv_bus_<N>`,
# generated from gridtokenx-smartmeter-simulator/backend/data/<grid>/p_load.csv columns).
# When set, one account is registered per serial (COUNT is overridden by the list length)
# and step 6 registers THAT serial instead of an invented GRID-<stamp>, so telemetry the
# simulator emits for the real meter attributes to the registered owner.
SERIALS=()
if [ -n "${SERIALS_FILE:-}" ]; then
    [ -r "$SERIALS_FILE" ] || { printf 'SERIALS_FILE not readable: %s\n' "$SERIALS_FILE" >&2; exit 1; }
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"  # trim
        [ -n "$line" ] && SERIALS+=("$line")
    done < "$SERIALS_FILE"
    [ "${#SERIALS[@]}" -gt 0 ] || { printf 'SERIALS_FILE has no serials: %s\n' "$SERIALS_FILE" >&2; exit 1; }
    COUNT="${#SERIALS[@]}"
fi

IAM_BASE="${IAM_BASE:-http://localhost:${IAM_HTTP_PORT:-4010}}"
METER_BASE="${METER_BASE:-http://localhost:${METER_SERVICE_PORT:-4062}}"
REDIS="${REDIS_CONTAINER:-gridtokenx-redis}"
SIM="${SIM_CONTAINER:-gridtokenx-smartmeter-simulator}"
GW_SECRET="${GATEWAY_SECRET:-gridtokenx-gateway-secret-2025}"
PASS="${DEFAULT_PASS:-TestPass123!}"
LAT="${LAT_E7:-13750000}"
LONG="${LONG_E7:-100500000}"
KEY_SECRET="${KEY_SECRET:-gridtokenx-sim}"
RPC_URL="${RPC_URL:-http://localhost:8899}"
AIRDROP_SOL="${AIRDROP_SOL:-10}"   # SOL airdropped to each verified account (0 disables)

c_grn='\033[0;32m'; c_red='\033[0;31m'; c_yel='\033[0;33m'; c_blu='\033[0;34m'; c_rst='\033[0m'
ok()   { printf "${c_grn}✔${c_rst} %s\n" "$*"; }
info() { printf "${c_blu}ℹ${c_rst} %s\n" "$*"; }
warn() { printf "${c_yel}⚠${c_rst} %s\n" "$*"; }
err()  { printf "${c_red}✘${c_rst} %s\n" "$*" >&2; }

# --- preflight ---------------------------------------------------------------
for bin in jq curl solana solana-keygen uuidgen; do
    command -v "$bin" >/dev/null 2>&1 || { err "$bin required but not installed"; exit 1; }
done
if ! curl -fsS -m 5 "$IAM_BASE/health" >/dev/null 2>&1; then
    err "IAM not reachable at $IAM_BASE/health"; exit 1
fi
if ! curl -fsS -m 5 "$METER_BASE/health" >/dev/null 2>&1; then
    err "meter-service not reachable at $METER_BASE/health (set METER_BASE / METER_SERVICE_PORT)"; exit 1
fi
if ! docker exec "$SIM" true 2>/dev/null; then
    err "sim container '$SIM' not running (needed for Ed25519 signing). Set SIM_CONTAINER."; exit 1
fi
if ! docker exec "$REDIS" redis-cli PING 2>/dev/null | grep -q PONG; then
    err "redis container '$REDIS' not reachable. Set REDIS_CONTAINER."; exit 1
fi
if [ "$AIRDROP_SOL" != "0" ] && ! solana cluster-version --url "$RPC_URL" >/dev/null 2>&1; then
    err "validator/RPC not reachable at $RPC_URL (needed for airdrop; set AIRDROP_SOL=0 to skip)"; exit 1
fi

# Nanosecond timestamp — BSD/macOS `date` lacks %N (emits literal "N" -> same-second
# collisions -> duplicate usernames -> register fails). Prefer gdate, then a %N-capable
# date, else fall back to seconds + a random tail so stamps stay unique.
if command -v gdate >/dev/null 2>&1; then
    now_ns() { gdate +%s%N; }
elif [ "$(date +%N 2>/dev/null)" != "N" ] && [ -n "$(date +%N 2>/dev/null)" ]; then
    now_ns() { date +%s%N; }
else
    warn "date lacks %N (BSD/macOS); using seconds + random tail for unique stamps"
    now_ns() { printf '%s%09d' "$(date +%s)" "$((RANDOM * RANDOM % 1000000000))"; }
fi

gw=(-H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: $GW_SECRET")

# Write the header when the file is missing OR empty (a pre-truncated `: > file` still
# exists, so a plain `-f` test would skip the header and leave a headerless TSV that
# breaks the feeder's csv.DictReader).
[ -s "$OUTFILE" ] || printf 'username\tpassword\temail\twallet_address\tserial_number\tmeter_id\tuser_id\n' > "$OUTFILE"

info "Registering $COUNT user(s) + one meter each -> $IAM_BASE"
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

    # 2. verify email (confirm account)
    vres=$(curl -s "$IAM_BASE/api/v1/auth/verify?token=verify_${email}")
    if [ "$(echo "$vres" | jq -r '.success // .data.success // empty')" = "true" ]; then
        ok "email verified (account confirmed)"
    else
        warn "verify unconfirmed: $(echo "$vres" | head -c160)"
    fi

    # 3. login
    token=$(curl -s -X POST "$IAM_BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
            -d "{\"username\":\"$username\",\"password\":\"$PASS\"}" \
            | jq -r '.access_token // .data.auth.access_token // empty')
    [ -z "$token" ] && { err "login failed"; fail_n=$((fail_n+1)); continue; }
    auth=(-H "Authorization: Bearer $token")

    # 4. link real wallet (hard-fail the row on non-2xx: an unlinked wallet leaves
    #    users.wallet_address NULL, so the bridge can't resolve a mint recipient and
    #    every surplus mint for this meter is silently deferred).
    kf=$(mktemp)
    solana-keygen new --no-bip39-passphrase --silent --force --outfile "$kf" >/dev/null 2>&1
    wallet=$(solana-keygen pubkey "$kf"); rm -f "$kf"
    wl_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$IAM_BASE/api/v1/me/wallets" "${gw[@]}" "${auth[@]}" \
         -H 'Content-Type: application/json' \
         -d "{\"wallet_address\":\"$wallet\",\"label\":\"Primary\",\"is_primary\":true}")
    case "$wl_code" in
        2??) ok "linked wallet $wallet (http=$wl_code)" ;;
        *)   err "wallet link failed http=$wl_code for $wallet"; fail_n=$((fail_n+1)); continue ;;
    esac

    # 4b. airdrop SOL to the confirmed account's wallet (validator faucet, dev-only)
    if [ "$AIRDROP_SOL" != "0" ]; then
        if solana airdrop "$AIRDROP_SOL" "$wallet" --url "$RPC_URL" >/dev/null 2>&1; then
            bal=$(solana balance "$wallet" --url "$RPC_URL" 2>/dev/null)
            ok "airdropped $AIRDROP_SOL SOL (balance: ${bal:-?})"
        else
            warn "airdrop failed for $wallet (validator up at $RPC_URL?)"
        fi
    fi

    # 5. on-chain registration (Registry PDA)
    if [ "${SKIP_ONCHAIN:-0}" != "1" ]; then
        onb=$(curl -s -w '\n%{http_code}' -X POST "$IAM_BASE/api/v1/me/registration" "${gw[@]}" "${auth[@]}" \
              -H 'Content-Type: application/json' \
              -d "{\"user_type\":\"prosumer\",\"location\":{\"lat_e7\":$LAT,\"long_e7\":$LONG}}")
        onb_code=$(printf '%s' "$onb" | tail -n1); onb_body=$(printf '%s' "$onb" | sed '$d')
        onb_status=$(printf '%s' "$onb_body" | jq -r '.status // "unknown"')
        # Not fatal: telemetry + mint resolve off owner+wallet (steps 4/7), not the PDA.
        case "$onb_code" in
            2??) info "on-chain status=$onb_status (http=$onb_code)" ;;
            *)   warn "on-chain registration http=$onb_code: $(printf '%s' "$onb_body" | head -c120)" ;;
        esac
    fi

    # 6. register meter via the real meter-service API -> real meter id (UUID)
    #    Serial = the simulator's real meter id when SERIALS_FILE is set, else GRID-<stamp>.
    if [ "${#SERIALS[@]}" -gt 0 ]; then serial="${SERIALS[$((i-1))]}"; else serial="GRID-${stamp}"; fi
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

    # 7. wire signing: deterministic Ed25519 pubkey (via sim container) + Redis maps
    #    keyed by serial (= telemetry device_id) so Aggregator Bridge ingest/mint resolves.
    pub=$(docker exec -e MID="$serial" -e SECRET="$KEY_SECRET" "$SIM" \
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
        warn "meter $serial signing-key derivation failed (telemetry disabled for this meter)"
    else
        docker exec "$REDIS" redis-cli SET "gridtokenx:devices:${serial}:pubkey" "$pub"    >/dev/null
        docker exec "$REDIS" redis-cli SET "gridtokenx:meters:${serial}:user_id" "$uid"    >/dev/null
        docker exec "$REDIS" redis-cli SET "gridtokenx:meters:${serial}:wallet"  "$wallet" >/dev/null
        ok "signing wired (pubkey + owner + wallet)"
    fi

    # 8. save creds
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$username" "$PASS" "$email" "$wallet" "$serial" "$meter_id" "$uid" >> "$OUTFILE"
    done_n=$((done_n+1))
done

printf '\n'
ok "Registered $done_n/$COUNT user(s) with one meter each."
[ "$fail_n" -gt 0 ] && warn "$fail_n failed (see log above)."
info "Credentials saved to: $OUTFILE"
