#!/usr/bin/env bash
# GridTokenX — bulk register users + attach one meter each (no telemetry/mint).
#
# Per user, end to end:
#   1. Register     POST /api/v1/auth/register            -> user_id
#   2. Verify email GET  /api/v1/auth/verify?token=verify_<email>  (confirm account;
#                     the response already carries a JWT — reused, so no login round-trip.
#                     A login is only issued as a fallback when verify returns no token.)
#   3. Link wallet  POST /api/v1/me/wallets               (real Solana keypair, primary)
#  3b. Airdrop      solana airdrop <AIRDROP_SOL> <wallet> (validator faucet, dev-only)
#   4. On-chain     POST /api/v1/me/registration          (Registry PDA via Chain Bridge)
#   5. Register meter POST /api/v1/meters (meter-service, JWT) -> REAL meter id (UUID)
#   6. Wire signing  deterministic Ed25519 device key (keyed by serial)
#                     -> gridtokenx:devices:<serial>:pubkey  (signing key)
#                     -> gridtokenx:meters:<serial>:user_id  (owner)
#                     -> gridtokenx:meters:<serial>:wallet   (mint recipient)
#   7. Save         append username,password,email,wallet,serial,meter_id,user_id to TSV
#
# Throughput: users run CONCURRENCY-wide in parallel (xargs -P re-invoking this
# script with --worker). All Ed25519 device pubkeys are precomputed in ONE sim
# container exec before the fan-out, and the 3 Redis keys per user are written
# with a single `redis-cli MSET` exec. Keep CONCURRENCY ≤16 — IAM's Argon2
# onboarding path saturates beyond that.
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
#   CONCURRENCY       parallel users        (default 8; keep ≤16 for IAM Argon2)
#   SKIP_ONCHAIN=1    skip step 4 (wallet link still runs)
#   SERIALS_FILE      newline-delimited real meter ids to use as serials (overrides
#                     COUNT with the list length). Use the simulator's reference-grid
#                     ids so real sim telemetry attributes to each owner, e.g.:
#                       cd gridtokenx-smartmeter-simulator/backend && python3 -c \
#                         "import csv;h=next(csv.reader(open('data/80_bus_rural_reference_grid/p_load.csv')));\
#                          print('\n'.join(f'ref_lv_bus_{b}' for b in h if b.lower()!='date'))" > real_ids.txt
#                       SERIALS_FILE=real_ids.txt ./scripts/register_users_meters.sh

set -uo pipefail

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
CONC="${CONCURRENCY:-8}"
SKIP_ONCHAIN="${SKIP_ONCHAIN:-0}"

c_grn='\033[0;32m'; c_red='\033[0;31m'; c_yel='\033[0;33m'; c_blu='\033[0;34m'; c_rst='\033[0m'
ok()   { printf "${c_grn}✔${c_rst} %s\n" "$*"; }
info() { printf "${c_blu}ℹ${c_rst} %s\n" "$*"; }
warn() { printf "${c_yel}⚠${c_rst} %s\n" "$*"; }
err()  { printf "${c_red}✘${c_rst} %s\n" "$*" >&2; }

log_api() { # step user http_code body — one JSON line, O_APPEND so parallel-safe
    jq -cn --arg step "$1" --arg user "$2" --arg code "$3" --arg body "$4" \
        '{step:$step,user:$user,http_code:($code|tonumber? // $code),body:($body|fromjson? // $body)}' \
        >> "$APILOG"
}

gw=(-H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: $GW_SECRET")

# --- worker mode: one user, args = i total stamp serial pub -------------------
# Invoked by the parent through xargs -P; all config comes exported via env.
run_one_user() { # $1=i $2=total $3=stamp $4=serial $5=pub("-"=missing)
    local i="$1" total="$2" stamp="$3" serial="$4" pub="$5"
    [ "$pub" = "-" ] && pub=""
    local username="user_${stamp}" email="user_${stamp}@example.com"

    # 1. register
    local reg reg_code reg_body uid
    reg=$(curl -s -w '\n%{http_code}' -X POST "$IAM_BASE/api/v1/auth/register" -H 'Content-Type: application/json' \
          -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$PASS\"}")
    reg_code=$(printf '%s' "$reg" | tail -n1); reg_body=$(printf '%s' "$reg" | sed '$d')
    log_api "register" "$username" "$reg_code" "$reg_body"
    uid=$(echo "$reg_body" | jq -r '.id // .data.id // empty')
    [ -z "$uid" ] && { err "register failed: $(echo "$reg_body" | head -c160)"; return 1; }
    ok "registered user_id=$uid"

    # 2. verify email (confirm account) — the response carries a JWT we reuse
    local vres v_code v_body token
    vres=$(curl -s -w '\n%{http_code}' "$IAM_BASE/api/v1/auth/verify?token=verify_${email}")
    v_code=$(printf '%s' "$vres" | tail -n1); v_body=$(printf '%s' "$vres" | sed '$d')
    log_api "verify" "$username" "$v_code" "$v_body"
    if [ "$(echo "$v_body" | jq -r '.success // .data.success // empty')" = "true" ]; then
        ok "email verified (account confirmed)"
    else
        warn "verify unconfirmed: $(echo "$v_body" | head -c160)"
    fi
    token=$(echo "$v_body" | jq -r '.auth.access_token // .data.auth.access_token // empty')

    # 2b. login fallback — only when verify returned no token (e.g. rerun on an
    #     already-verified account)
    if [ -z "$token" ]; then
        local lres l_code l_body
        lres=$(curl -s -w '\n%{http_code}' -X POST "$IAM_BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
                -d "{\"username\":\"$username\",\"password\":\"$PASS\"}")
        l_code=$(printf '%s' "$lres" | tail -n1); l_body=$(printf '%s' "$lres" | sed '$d')
        log_api "login" "$username" "$l_code" "$l_body"
        token=$(echo "$l_body" | jq -r '.access_token // .data.auth.access_token // empty')
    fi
    [ -z "$token" ] && { err "no token from verify or login"; return 1; }
    local auth=(-H "Authorization: Bearer $token")

    # 3. link real wallet (hard-fail the row on non-2xx: an unlinked wallet leaves
    #    users.wallet_address NULL, so the bridge can't resolve a mint recipient and
    #    every surplus mint for this meter is silently deferred).
    local kf wallet wlres wl_code wl_body
    kf=$(mktemp)
    solana-keygen new --no-bip39-passphrase --silent --force --outfile "$kf" >/dev/null 2>&1
    wallet=$(solana-keygen pubkey "$kf"); rm -f "$kf"
    wlres=$(curl -s -w '\n%{http_code}' -X POST "$IAM_BASE/api/v1/me/wallets" "${gw[@]}" "${auth[@]}" \
         -H 'Content-Type: application/json' \
         -d "{\"wallet_address\":\"$wallet\",\"label\":\"Primary\",\"is_primary\":true}")
    wl_code=$(printf '%s' "$wlres" | tail -n1); wl_body=$(printf '%s' "$wlres" | sed '$d')
    log_api "link_wallet" "$username" "$wl_code" "$wl_body"
    case "$wl_code" in
        2??) ok "linked wallet $wallet (http=$wl_code)" ;;
        *)   err "wallet link failed http=$wl_code for $wallet"; return 1 ;;
    esac

    # 3b. airdrop SOL to the confirmed account's wallet (validator faucet, dev-only).
    #     No balance read-back — it cost an extra RPC round-trip for a log line.
    if [ "$AIRDROP_SOL" != "0" ]; then
        local ad_out
        if ad_out=$(solana airdrop "$AIRDROP_SOL" "$wallet" --url "$RPC_URL" 2>&1); then
            log_api "airdrop" "$username" "ok" "$ad_out"
            ok "airdropped $AIRDROP_SOL SOL"
        else
            log_api "airdrop" "$username" "fail" "$ad_out"
            warn "airdrop failed for $wallet (validator up at $RPC_URL?)"
        fi
    fi

    # 4. on-chain registration (Registry PDA)
    if [ "$SKIP_ONCHAIN" != "1" ]; then
        local onb onb_code onb_body onb_status
        onb=$(curl -s -w '\n%{http_code}' -X POST "$IAM_BASE/api/v1/me/registration" "${gw[@]}" "${auth[@]}" \
              -H 'Content-Type: application/json' \
              -d "{\"user_type\":\"prosumer\",\"location\":{\"lat_e7\":$LAT,\"long_e7\":$LONG}}")
        onb_code=$(printf '%s' "$onb" | tail -n1); onb_body=$(printf '%s' "$onb" | sed '$d')
        log_api "onchain_register" "$username" "$onb_code" "$onb_body"
        onb_status=$(printf '%s' "$onb_body" | jq -r '.status // "unknown"')
        # Not fatal: telemetry + mint resolve off owner+wallet (steps 3/6), not the PDA.
        case "$onb_code" in
            2??) info "on-chain status=$onb_status (http=$onb_code)" ;;
            *)   warn "on-chain registration http=$onb_code: $(printf '%s' "$onb_body" | head -c120)" ;;
        esac
    fi

    # 5. register meter via the real meter-service API -> real meter id (UUID)
    local mres m_code mreg meter_id reg_serial
    mres=$(curl -s -w '\n%{http_code}' -X POST "$METER_BASE/api/v1/meters" "${auth[@]}" \
           -H 'Content-Type: application/json' \
           -d "{\"serial_number\":\"$serial\",\"meter_type\":\"smart_meter\",\"location\":\"Bangkok\",\"latitude\":13.75,\"longitude\":100.5}")
    m_code=$(printf '%s' "$mres" | tail -n1); mreg=$(printf '%s' "$mres" | sed '$d')
    log_api "register_meter" "$username" "$m_code" "$mreg"
    meter_id=$(echo "$mreg" | jq -r '.meter.id // empty')
    reg_serial=$(echo "$mreg" | jq -r '.meter.serial_number // empty')
    if [ -z "$meter_id" ]; then
        err "meter register failed: $(echo "$mreg" | head -c200)"; return 1
    fi
    serial="${reg_serial:-$serial}"
    ok "meter registered id=$meter_id serial=$serial"

    # 6. wire signing: precomputed Ed25519 pubkey + Redis maps, one MSET exec.
    #    Keyed by serial (= telemetry device_id) so Aggregator Bridge ingest/mint resolves.
    if [ -z "$pub" ]; then
        warn "meter $serial signing-key derivation failed (telemetry disabled for this meter)"
    else
        docker exec "$REDIS" redis-cli MSET \
            "gridtokenx:devices:${serial}:pubkey" "$pub" \
            "gridtokenx:meters:${serial}:user_id" "$uid" \
            "gridtokenx:meters:${serial}:wallet"  "$wallet" >/dev/null
        ok "signing wired (pubkey + owner + wallet)"
    fi

    # 7. save creds (single O_APPEND line — parallel-safe)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$username" "$PASS" "$email" "$wallet" "$serial" "$meter_id" "$uid" >> "$OUTFILE"
    return 0
}

if [ "${1:-}" = "--worker" ]; then
    shift
    # Buffer the whole user block and emit it in one write so parallel workers
    # don't interleave mid-user on the console.
    block=$(run_one_user "$@" 2>&1); rc=$?
    printf '%b user %s/%s: user_%s\n%s\n\n' "${c_blu}ℹ${c_rst}" "$1" "$2" "$3" "$block"
    [ "$rc" -ne 0 ] && : > "$REG_TMP/fail.$1"
    exit 0
fi

# --- parent mode --------------------------------------------------------------

COUNT="${1:-80}"
OUTFILE="${2:-$(cd "$(dirname "$0")" && pwd)/registered_users_meters.txt}"

# SERIALS_FILE: optional path to a newline-delimited list of REAL meter ids to use as
# each account's meter serial (e.g. the simulator's reference-grid ids `ref_lv_bus_<N>`,
# generated from gridtokenx-smartmeter-simulator/backend/data/<grid>/p_load.csv columns).
# When set, one account is registered per serial (COUNT is overridden by the list length)
# and step 5 registers THAT serial instead of an invented GRID-<stamp>, so telemetry the
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

# --- preflight ---------------------------------------------------------------
for bin in jq curl solana solana-keygen xargs; do
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

# Write the header when the file is missing OR empty (a pre-truncated `: > file` still
# exists, so a plain `-f` test would skip the header and leave a headerless TSV that
# breaks the feeder's csv.DictReader).
[ -s "$OUTFILE" ] || printf 'username\tpassword\temail\twallet_address\tserial_number\tmeter_id\tuser_id\n' > "$OUTFILE"

# Full raw response log — one JSON-line record per API call (step, http code, body),
# distinct from OUTFILE (creds TSV) so the feeder's csv.DictReader is unaffected.
APILOG="${APILOG:-$(cd "$(dirname "$0")" && pwd)/register_users_meters.api.log}"
: > "$APILOG"

REG_TMP=$(mktemp -d)
trap 'rm -rf "$REG_TMP"' EXIT

# Pre-assign stamps + serials so the whole run's device keys can be derived in
# ONE sim container exec (the old per-user exec paid ~0.9s of python/uv startup
# per meter).
i=1
STAMPS=(); ALL_SERIALS=()
while [ "$i" -le "$COUNT" ]; do
    stamp=$(now_ns)
    STAMPS[$i]="$stamp"
    if [ "${#SERIALS[@]}" -gt 0 ]; then ALL_SERIALS[$i]="${SERIALS[$((i-1))]}"; else ALL_SERIALS[$i]="GRID-${stamp}"; fi
    i=$((i+1))
done

info "Registering $COUNT user(s) + one meter each -> $IAM_BASE (concurrency=$CONC)"
info "Credentials: $OUTFILE"
info "Full API responses: $APILOG"
info "Precomputing $COUNT Ed25519 device key(s) in one sim exec..."

PUBMAP=$(printf '%s\n' "${ALL_SERIALS[@]:1}" | docker exec -i -e SECRET="$KEY_SECRET" "$SIM" \
    sh -c 'cat > /tmp/mk_batch.py <<"PY"
import sys, os, hashlib
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
sec = os.environ["SECRET"]
for line in sys.stdin:
    mid = line.strip()
    if not mid:
        continue
    seed = hashlib.sha256(f"{sec}:{mid}".encode()).digest()
    p = Ed25519PrivateKey.from_private_bytes(seed)
    print(mid, p.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex())
PY
uv run python /tmp/mk_batch.py' 2>/dev/null)

# Map pubkeys back by input order (the batch script emits one line per serial in order).
PUBS=()
i=1
while IFS=' ' read -r _serial _hex; do
    [ -n "${_hex:-}" ] && PUBS[$i]="$_hex"
    i=$((i+1))
done <<< "$PUBMAP"

# Manifest: one line per user -> xargs fans out --worker invocations.
MANIFEST="$REG_TMP/manifest.txt"
i=1
while [ "$i" -le "$COUNT" ]; do
    printf '%s %s %s %s %s\n' "$i" "$COUNT" "${STAMPS[$i]}" "${ALL_SERIALS[$i]}" "${PUBS[$i]:--}" >> "$MANIFEST"
    i=$((i+1))
done

export IAM_BASE METER_BASE REDIS SIM GW_SECRET PASS LAT LONG KEY_SECRET \
       RPC_URL AIRDROP_SOL SKIP_ONCHAIN OUTFILE APILOG REG_TMP CONC

xargs -P "$CONC" -L 1 bash "$0" --worker < "$MANIFEST"

fail_n=$(find "$REG_TMP" -name 'fail.*' | wc -l | tr -d ' ')
done_n=$((COUNT - fail_n))

printf '\n'
ok "Registered $done_n/$COUNT user(s) with one meter each."
[ "$fail_n" -gt 0 ] && warn "$fail_n failed (see log above)."
info "Credentials saved to: $OUTFILE"
info "Full API responses: $APILOG"
