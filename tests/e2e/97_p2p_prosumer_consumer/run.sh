#!/usr/bin/env bash
# Suite 97 — P2P Energy Trade: Prosumer ↔ Consumer (standalone bash).
#
# Two users (1 prosumer, 1 consumer) go through the FULL self-service lifecycle
# using real APIs only (no Redis/DB backdoor for registration) — register,
# verify, on-chain onboard, add a meter to each account — then the prosumer
# proves REAL surplus by pushing signed GENERATION telemetry into the Aggregator
# Bridge, and the two trade so the CDA matcher fills a real prosumer→consumer
# cross.
#
# Distinct from suite 90_golden_path (which uses a Redis backdoor for meter
# registration and is service-generic seller/buyer): here both meters are
# registered via the real meter-service API and roles are prosumer/consumer.
#
# Flow:
#   Phase 1  Register        POST /api/v1/auth/register            (both users)
#   Phase 2  Verify email    GET  /api/v1/auth/verify?token=...    -> airdrop + custodial wallet + PDA
#   Phase 3  On-chain reg     POST /api/v1/me/registration          (user_type prosumer|consumer)
#            + GATE on IAM users.blockchain_registered (detached ~14-30s)
#   Phase 4  Add meter        POST /api/v1/meters (meter-service)   -> real meter id (UUID), both users
#            + wire telemetry attribution (device pubkey + owner + wallet) at a REAL sim device id
#   Phase 5  Prove surplus    prosumer sends signed GENERATION readings (AES-256-GCM dlms-enc + mTLS,
#                             in sim container) — best-effort proof of real surplus BEFORE selling
#            Verify meter     POST /api/v1/meters/<serial>/verify  [HARD GATE]
#                             Registration only CLAIMS a serial; Trading refuses a sell (403)
#                             until the meter is verified against the signed telemetry above.
#            Trade            prosumer SELL x consumer BUY (crossing) -> POST /api/v1/orders
#            Match            wait for MatcherWorker, assert our orders filled  [HARD GATE]
#   Phase 6  Evidence         best-effort: aggregator-bridge settlement + chain-bridge mint logs
#
# HARD prerequisite: IAM up. HARD gate: the P2P match (Phase 5 crossing fills).
# Everything telemetry/settlement/mint is best-effort (warn+continue, like golden path).
#
# Usage:  ./tests/e2e/97_p2p_prosumer_consumer/run.sh
#
# Env overrides: see env.sh for endpoints/secrets. Suite-local knobs:
#   SELL_PRICE (4.00) BUY_PRICE (4.50, >= SELL) TRADE_KWH (5) ZONE_ID (1)
#   SETTLE_WAIT (10)   seconds to wait for the CDA matcher to fill the crossed book
#   REG_CONFIRM_WAIT (45) seconds to wait for detached on-chain reg to confirm
#   SURPLUS_TICKS (3)  how many signed generation readings the prosumer pushes
#   GEN_KWH (6) CONS_KWH (1)   per-reading generation/consumption (net must be > 0)
#   SKIP_SURPLUS=1     skip Phase 5 telemetry (go straight to orders). NOTE: this now
#                      also strands meter verification — with no attested readings the
#                      verify step fails and the prosumer cannot sell. Only useful
#                      against a stack where the meter is already verified.
#   SKIP_ONCHAIN=1     skip Phase 3 (custodial already auto-registered on verify)
#   WIRE_TELEMETRY=0   register meters with invented serials, don't re-point sim attribution

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"

# --- endpoints (from env.sh, with suite-friendly aliases) ---
IAM_BASE="${IAM_BASE:-$IAM_URL}"                                     # http://localhost:4010
METER_BASE="${METER_BASE:-http://localhost:${METER_SERVICE_PORT:-4062}}"
SIM_REST_BASE="${SIM_REST_BASE:-$SIMULATOR_URL}"          # sim's own REST API (env.sh: host 12010 -> container 8082)
# Trading gateway. Defaults to the SAME APISIX endpoint env.sh already resolved,
# not the .orb.local hostname: OrbStack's domain proxy stopped landing on a
# serving container port after a container recreate, so every request there 404'd
# — including auth-exempt /health — while both real listeners (9080 -> :4001 and
# 9443 -> :8443) served routes correctly. That produced a suite failure that read
# as a broken trading service when the gateway was fine.
GW="${GW:-$APISIX_URL}"
GW_SECRET="${GATEWAY_SECRET}"
PASS="${E2E_PASSWORD}"

# --- containers ---
SIM_CONTAINER="${SIM_CONTAINER:-gridtokenx-smartmeter-simulator}"
REDIS_CONTAINER="${REDIS_CONTAINER:-gridtokenx-redis}"
CHAIN_BRIDGE_CONTAINER="${CHAIN_BRIDGE_CONTAINER:-gridtokenx-chain-bridge}"
AGG_CONTAINER="${AGG_CONTAINER:-gridtokenx-aggregator-bridge}"
KEY_SECRET="${KEY_SECRET:-gridtokenx-sim}"          # sim's per-meter Ed25519 seed secret (MeterKey default)

# --- knobs ---
WIRE_TELEMETRY="${WIRE_TELEMETRY:-1}"
ZONE_ID="${ZONE_ID:-1}"
SELL_PRICE="${SELL_PRICE:-4.00}"
BUY_PRICE="${BUY_PRICE:-4.50}"
TRADE_KWH="${TRADE_KWH:-5}"
LAT="${LAT_E7:-13750000}"
LONG="${LONG_E7:-100500000}"
SETTLE_WAIT="${SETTLE_WAIT:-10}"
REG_CONFIRM_WAIT="${REG_CONFIRM_WAIT:-45}"
SURPLUS_TICKS="${SURPLUS_TICKS:-3}"
GEN_KWH="${GEN_KWH:-6}"
CONS_KWH="${CONS_KWH:-1}"
SIM_CANDIDATE_POOL="${SIM_CANDIDATE_POOL:-25}"

c_grn='\033[0;32m'; c_red='\033[0;31m'; c_yel='\033[0;33m'; c_blu='\033[0;34m'; c_rst='\033[0m'
ok()   { printf "${c_grn}✔${c_rst} %s\n" "$*"; }
info() { printf "${c_blu}ℹ${c_rst} %s\n" "$*"; }
warn() { printf "${c_yel}⚠${c_rst} %s\n" "$*"; }
err()  { printf "${c_red}✘${c_rst} %s\n" "$*" >&2; }
step() { printf "\n${c_blu}== %s ==${c_rst}\n" "$*"; }

for bin in jq curl; do
    command -v "$bin" >/dev/null 2>&1 || { err "$bin required but not installed"; exit 1; }
done

# HARD prerequisite: IAM must be up (mirrors golden path's skipif-not-up).
curl -fsS -m 5 "$IAM_BASE/health" >/dev/null 2>&1 || { err "IAM not reachable at $IAM_BASE/health — cannot run suite"; exit 1; }
# meter-service is required (Phase 4 uses its real API, no backdoor).
curl -fsS -m 5 "$METER_BASE/health" >/dev/null 2>&1 || { err "meter-service not reachable at $METER_BASE/health (set METER_BASE / METER_SERVICE_PORT)"; exit 1; }

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1; then HAVE_DOCKER=1; fi
if [ "$WIRE_TELEMETRY" = "1" ] && [ "$HAVE_DOCKER" != "1" ]; then
    warn "docker not available — telemetry attribution + signed surplus disabled (WIRE_TELEMETRY=0)"
    WIRE_TELEMETRY=0
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
# actually confirms (users.blockchain_registered = t). verify/registration return 200
# optimistically ~14-30s before the Registry PDA lands (register-flow-async-detached-gaps).
# Degrades to a warn if the DB container isn't reachable.
wait_onchain_confirmed() {
    local uid="$1" i reg
    if [ "$HAVE_DOCKER" != "1" ] || ! docker exec "$PG_CONTAINER" true >/dev/null 2>&1; then
        warn "DB ($PG_CONTAINER) unreachable — skipping on-chain confirm gate; trade may race registration"
        return 0
    fi
    for i in $(seq 1 "$REG_CONFIRM_WAIT"); do
        # PG_DB_IAM, not PG_DB: `users` moved to gridtokenx_iam. The shared DB still
        # has an EMPTY `users`, so this query returned '' rather than erroring — the
        # gate then burned its full 45s and warned "NOT confirmed" on accounts that
        # were registered 30ms after creation. Measured 2026-08-02: it had never
        # once passed, costing 90s a run while asserting nothing.
        reg=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB_IAM" -tAc \
              "SELECT blockchain_registered FROM users WHERE id='$uid';" 2>/dev/null | tr -d '[:space:]')
        case "$reg" in
            t|true) ok "on-chain registration CONFIRMED (blockchain_registered=t, ${i}s)"; return 0 ;;
        esac
        sleep 1
    done
    warn "on-chain registration NOT confirmed after ${REG_CONFIRM_WAIT}s (blockchain_registered='${reg:-null}') — on-chain order leg may fail"
    return 0
}

# pick_sim_meters -> sets PROSUMER_SIM_CANDIDATES / CONSUMER_SIM_CANDIDATES to pools of
# REAL device ids from the sim's own API (has_solar=true for the generation-capable
# prosumer, false for the consumer). A meter is one-owner, so onboard() retries down
# the pool until one is free.
pick_sim_meters() {
    PROSUMER_SIM_CANDIDATES=""; CONSUMER_SIM_CANDIDATES=""
    [ "$WIRE_TELEMETRY" = "1" ] || return 0
    local list n="$SIM_CANDIDATE_POOL"
    list=$(curl -s -m10 "$SIM_REST_BASE/api/v1/meters?limit=2000" 2>/dev/null)
    PROSUMER_SIM_CANDIDATES=$(echo "$list" | jq -r --argjson n "$n" \
        '[.meters[]? | select(.has_solar==true) | .meter_id][0:$n] | join(" ")' 2>/dev/null)
    CONSUMER_SIM_CANDIDATES=$(echo "$list" | jq -r --argjson n "$n" \
        '[.meters[]? | select(.has_solar==false) | .meter_id][0:$n] | join(" ")' 2>/dev/null)
    if [ -n "$PROSUMER_SIM_CANDIDATES" ]; then
        ok "sim prosumer candidates (has_solar): $(echo "$PROSUMER_SIM_CANDIDATES" | wc -w | tr -d ' ')"
    else
        info "no free solar-capable sim device — prosumer will use this run's own serial (still real signed telemetry)"
    fi
    [ -n "$CONSUMER_SIM_CANDIDATES" ] && ok "sim consumer candidates: $(echo "$CONSUMER_SIM_CANDIDATES" | wc -w | tr -d ' ')"
}

# wire_signing <serial> <user_id> <wallet> — re-derive the sim's deterministic Ed25519
# pubkey for this meter (seed = sha256("KEY_SECRET:serial"), same formula MeterKey uses)
# and re-point the bridge's Redis device registry (pubkey + owner + wallet) at this run's
# user, so signed telemetry for that serial attributes + mints to our user.
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
    docker exec "$REDIS_CONTAINER" redis-cli SET "gridtokenx:devices:${serial}:pubkey" "$pub"    >/dev/null 2>&1
    docker exec "$REDIS_CONTAINER" redis-cli SET "gridtokenx:meters:${serial}:user_id" "$uid"    >/dev/null 2>&1
    docker exec "$REDIS_CONTAINER" redis-cli SET "gridtokenx:meters:${serial}:wallet"  "$wallet" >/dev/null 2>&1
    ok "telemetry attribution wired: sim meter $serial -> user=$uid wallet=$wallet"
}

# onboard <user_type> <sim_candidates> -> sets globals:
# USERNAME EMAIL WALLET TOKEN USER_ID METER_ID SERIAL REAL_MATCH
onboard() {
    local user_type="$1" sim_candidates="${2:-}" stamp username email reg uid vres token wres wallet meter_id serial
    stamp=$(now_ns)
    username="e2e_p2p_${user_type}_${stamp}"; email="${username}@example.com"
    info "onboard $user_type: $username"

    # Phase 1 — register
    reg=$(curl -s -X POST "$IAM_BASE/api/v1/auth/register" -H 'Content-Type: application/json' \
          -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$PASS\"}")
    uid=$(echo "$reg" | jq -r '.id // .data.id // empty')
    [ -z "$uid" ] && { err "register failed: $(echo "$reg" | head -c160)"; return 1; }
    ok "registered user_id=$uid"

    # Phase 2 — verify -> auto airdrop + custodial wallet + detached on-chain PDA
    vres=$(curl -s "$IAM_BASE/api/v1/auth/verify?token=verify_${email}")
    if [ "$(echo "$vres" | jq -r '.success // .data.success // empty')" = "true" ]; then
        ok "email verified (auto: airdrop + custodial wallet)"
    else
        warn "verify unconfirmed: $(echo "$vres" | head -c160)"
    fi

    # login
    token=$(curl -s -X POST "$IAM_BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
            -d "{\"username\":\"$username\",\"password\":\"$PASS\"}" \
            | jq -r '.access_token // .data.auth.access_token // empty')
    [ -z "$token" ] && { err "login failed: $username"; return 1; }
    local auth=(-H "Authorization: Bearer $token")

    # read custodial wallet (the "confirm wallet" step — assert non-empty, not user-supplied)
    wres=$(curl -s "$IAM_BASE/api/v1/me/wallets" "${gw[@]}" "${auth[@]}")
    wallet=$(echo "$wres" | jq -r '
        [ (.wallets // .data.wallets // .data // .) | (if type=="array" then . else [.] end)[] ]
        | (map(select(.is_primary==true)) + .)
        | .[0].wallet_address // .[0].address // empty')
    if [ -z "$wallet" ]; then warn "no custodial wallet found: $(echo "$wres" | head -c120)"; else ok "custodial wallet $wallet"; fi

    # Phase 3 — on-chain registration with the intended user_type (idempotent)
    if [ "${SKIP_ONCHAIN:-0}" != "1" ]; then
        local onb onb_code onb_body onb_status
        onb=$(curl -s -w '\n%{http_code}' -X POST "$IAM_BASE/api/v1/me/registration" "${gw[@]}" "${auth[@]}" \
              -H 'Content-Type: application/json' \
              -d "{\"user_type\":\"$user_type\",\"location\":{\"lat_e7\":$LAT,\"long_e7\":$LONG}}")
        onb_code=$(printf '%s' "$onb" | tail -n1); onb_body=$(printf '%s' "$onb" | sed '$d')
        onb_status=$(printf '%s' "$onb_body" | jq -r '.status // "unknown"')
        case "$onb_code" in
            2??) info "on-chain status=$onb_status (http=$onb_code)" ;;
            409) info "on-chain already registered (http=409, idempotent)" ;;
            *)   warn "on-chain registration http=$onb_code: $(printf '%s' "$onb_body" | head -c120)" ;;
        esac
        # GATE on the detached confirmation (blockchain_registered=t) before trading.
        wait_onchain_confirmed "$uid"
    fi

    # Phase 4 — add a meter to the account (real meter-service API -> real UUID).
    # Tier 1: try each real sim device id (retry: a meter is one-owner, prior runs 409).
    # Tier 2: this run's own serial. NOT a degraded path — step 3 signs telemetry for
    #   whatever serial lands here, so the suite is fully self-sufficient and claims
    #   nothing from the finite pool. Tier 1 is kept only because attributing a device
    #   the live simulator is ALSO emitting for is a slightly more realistic fixture.
    meter_id=""; serial=""; local real_match=0
    local fallback="GRID-${user_type}-${stamp}" candidate mreg mid
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
        err "meter registration failed for $username (all sim candidates + fallback exhausted)"
        return 1
    fi
    ok "meter registered id=$meter_id serial=$serial (real_sim=$real_match)"

    # Point telemetry attribution at this user. Needed for an INVENTED serial too,
    # not just a claimed pool device: send_surplus registers the serial's pubkey and
    # enc key, but never the owner — `gridtokenx:meters:<serial>:{user_id,wallet}` is
    # written only here, and without it an accepted reading attributes to nobody and
    # the meter can never verify. For a real pool device this re-points an existing
    # mapping; for our own serial it creates the only one. Same call either way.
    if [ "$WIRE_TELEMETRY" = "1" ]; then
        wire_signing "$serial" "$uid" "$wallet"
    fi

    USERNAME="$username"; EMAIL="$email"; WALLET="$wallet"; TOKEN="$token"; USER_ID="$uid"
    METER_ID="$meter_id"; SERIAL="$serial"; REAL_MATCH="$real_match"
}

# send_surplus <serial> — prosumer pushes SURPLUS_TICKS signed GENERATION readings for
# its exact serial over the bridge's SECURE ingest path (AES-256-GCM dlms-enc + mTLS),
# with a DETERMINISTIC surplus (GEN_KWH - CONS_KWH > 0). Runs inside the sim container
# so it reuses the sim's own configured TLS client cert + aggregator API key (the same
# config that makes the sim's live emission land) — the bridge ingest port is
# ALWAYS-TLS, so a plaintext http sender gets a RemoteProtocolError, not a clean 4xx
# (memory aggregator-bridge-always-tls-port). register_enckeys_redis seeds the per-meter
# GUEK so the bridge can decrypt; register_pubkeys re-asserts the Ed25519 pubkey.
# Sets SURPLUS_ACCEPTED=<n>. Best-effort: failures warn but don't fail the suite.
send_surplus() {
    local serial="$1" out
    SURPLUS_ACCEPTED=0
    if [ "$HAVE_DOCKER" != "1" ]; then warn "docker unavailable — skip signed surplus"; return 0; fi
    out=$(docker exec \
        -e SERIAL="$serial" -e GEN_KWH="$GEN_KWH" -e CONS_KWH="$CONS_KWH" -e TICKS="$SURPLUS_TICKS" \
        "$SIM_CONTAINER" sh -c 'cat > /tmp/p2p_surplus.py <<"PY"
import asyncio, os, sys, time
sys.path.insert(0, "/app/src")
from datetime import datetime, timezone
from smart_meter_simulator.config import get_config
from smart_meter_simulator.models.reading import EnergyReading
from smart_meter_simulator.transport.aggregator_bridge import (
    AggregatorBridgeClient, MeterKey, register_pubkeys_redis, register_enckeys_redis,
)

async def main():
    serial = os.environ["SERIAL"]
    gen = float(os.getenv("GEN_KWH", "6")); cons = float(os.getenv("CONS_KWH", "1"))
    ticks = int(os.getenv("TICKS", "3"))
    net = round(gen - cons, 6)
    if net <= 0:
        print(f"FATAL net_kwh must be > 0 (gen={gen} cons={cons})"); return
    cfg = get_config()
    key = MeterKey(serial)
    register_pubkeys_redis(cfg.redis_url, [key])
    register_enckeys_redis(cfg.redis_url, [key])
    client_cert = (
        (cfg.aggregator_tls_client_cert, cfg.aggregator_tls_client_key)
        if cfg.aggregator_tls_client_cert and cfg.aggregator_tls_client_key else None
    )
    client = AggregatorBridgeClient(
        base_url=cfg.aggregator_bridge_url, api_key=cfg.aggregator_api_key,
        verify=cfg.aggregator_tls_ca or True, client_cert=client_cert,
    )
    # The bridge anti-replay counter (gridtokenx:devices:<serial>:ic) is MICROSECONDS
    # (sim emitter uses time.time_ns()//1000); a millisecond base is 1000x too small and
    # every frame 409s as a replay. Match the microsecond scale and lead the concurrent
    # sim writer by ~1s so our frames are strictly-increasing above the live counter (the
    # sim self-heals within ~1s once wall-clock passes our lead).
    base = time.time_ns() // 1000 + 1_000_000; ok = 0
    try:
        for i in range(ticks):
            r = EnergyReading(
                meter_id=serial, timestamp=datetime.now(timezone.utc), sequence_number=i + 1,
                energy_generated=gen, energy_consumed=cons, surplus_energy=net, deficit_energy=0.0,
                interval_seconds=900, voltage=230.0, current=10.0, power_factor=0.99, frequency=50.0,
                location="e2e-p2p", meter_type="solar", user_type="prosumer",
            )
            try:
                resp = await client.send_reading(r, key, encrypt=True, counter=base + i + 1)
                print(f"ACCEPTED {i+1} {resp.status_code}"); ok += 1
            except Exception as e:  # noqa: BLE001
                print(f"REJECTED {i+1} {type(e).__name__}: {str(e)[:160]}")
    finally:
        await client.close()
    print(f"SUMMARY ok={ok}/{ticks} net={net} enc=dlms-enc")

asyncio.run(main())
PY
uv run python /tmp/p2p_surplus.py' 2>&1)
    SURPLUS_ACCEPTED=$(echo "$out" | grep -c '^ACCEPTED ')
    if [ "${SURPLUS_ACCEPTED:-0}" -gt 0 ]; then
        ok "signed surplus ACCEPTED $SURPLUS_ACCEPTED/$SURPLUS_TICKS (serial=$serial gen=$GEN_KWH cons=$CONS_KWH net>0, dlms-enc+mTLS)"
    else
        warn "signed surplus not accepted: $(echo "$out" | grep -Ei 'REJECTED|FATAL|SUMMARY|Error' | head -2 | tr '\n' ' ' | head -c220)"
    fi
}

# verify_meter <token> <serial> — prove possession of the meter so its owner may
# open sell orders. Trading REFUSES a sell (403) unless the seller has a verified
# meter, and meter registration no longer auto-verifies: it only claims a serial.
# meter-service passes this when the Aggregator Bridge has already accepted at
# least one signature-verified reading for that serial under this owner — which
# is precisely what send_surplus above produces, so this must run AFTER it.
#
# Uses the legacy `/api/v1/meters/...` base for consistency with the registration
# call above (same service, same handler); the canonical form is
# POST /api/v1/me/meters/{serial}/verify.
# verify_meter <token> <serial> — POST the verify endpoint, RETRYING a 409.
#
# The 409 is racy, not terminal: the bridge ACKs an ingest frame before its batched
# INSERT commits, so `send_surplus` can report ACCEPTED 3/3 while meter_readings is
# still empty. Measured 2026-08-02 from the verification audit trail — attempt at
# 14:36:21.335, rows committed at 14:36:21.927, i.e. the suite asked 592ms too
# early and read the miss as "this meter can never be verified". Poll instead of
# sleeping a flat guess: the wait is usually one tick.
VERIFY_TRIES="${VERIFY_TRIES:-15}"
VERIFY_DELAY="${VERIFY_DELAY:-2}"
verify_meter() {
    local token="$1" serial="$2" resp code body attempt=1
    while :; do
        resp=$(curl -sk -m20 -w '\n%{http_code}' -X POST \
            "${METER_BASE}/api/v1/meters/${serial}/verify" \
            -H "Authorization: Bearer $token" -H 'Content-Type: application/json')
        code=$(printf '%s' "$resp" | tail -n1); body=$(printf '%s' "$resp" | sed '$d')
        case "$code" in
            2??)
                ok "meter verified: serial=$serial attested=$(printf '%s' "$body" | jq -r '.attestation.attested_readings // "?"') already=$(printf '%s' "$body" | jq -r '.already_verified // false')${attempt:+ (attempt $attempt)}"
                return 0
                ;;
            409)
                if [ "$attempt" -lt "$VERIFY_TRIES" ]; then
                    info "attestation not visible yet (attempt $attempt/$VERIFY_TRIES) — readings may still be committing"
                    attempt=$((attempt+1)); sleep "$VERIFY_DELAY"; continue
                fi
                err "meter $serial has no signature-verified telemetry after $((VERIFY_TRIES * VERIFY_DELAY))s — it cannot be verified, so its owner cannot sell."
                err "  Cause: the surplus step above did not land readings for this exact serial."
                err "  $(printf '%s' "$body" | jq -r '.error // empty' | head -c200)"
                return 1
                ;;
            *)
                err "meter verification failed (http=$code): $(printf '%s' "$body" | head -c200)"
                return 1
                ;;
        esac
    done
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

# grep_recent_log <container> <pattern> <label> — best-effort settlement/mint evidence.
grep_recent_log() {
    local ctr="$1" pat="$2" label="$3" hit
    [ "$HAVE_DOCKER" = "1" ] || { warn "$label: docker unavailable — SKIP"; return 0; }
    docker inspect "$ctr" >/dev/null 2>&1 || { warn "$label: container $ctr not found — SKIP"; return 0; }
    hit=$(docker logs --since 3m "$ctr" 2>&1 | grep -Ei "$pat" | tail -3)
    if [ -n "$hit" ]; then
        ok "$label evidence in $ctr:"; echo "$hit" | sed 's/^/    /'
    else
        warn "$label: no '$pat' in $ctr logs (last 3m) — SKIP (async, may lag)"
    fi
}

# assert_mint_health — is the surplus-mint path actually WORKING?
#
# This replaces a grep for "Success|mint" against the chain-bridge log. That
# pattern matched the word "mint" case-insensitively, so the line
#   "⚠️ Mint chunk [0..1] failed: ... landed with an on-chain error"
# was printed as "✔ mint evidence" — a failure rendered as proof of success, the
# single most misleading thing a harness can do. Observed on every run of
# 2026-08-02 while not one mint had confirmed for hours.
#
# The authoritative signal is the aggregator's own structured counter,
#   "⚡ batch surplus mint: <n> confirmed, <m> failed of <k> submitted".
# A batch that submitted work and confirmed NONE of it means the mint path is
# broken platform-wide, whether or not this run's 15-minute bin was in that batch
# (it usually is not — a bin must close first, which outlives the suite).
#
# This is a GATE, not evidence-gathering: a suite that passes while the mint is
# down is exactly the "green means nothing" failure this file has twice been
# fixed for. Set ALLOW_MINT_FAILURE=1 to downgrade it to a warning when the
# breakage is known and accepted — e.g. a local validator whose Clock sysvar has
# drifted behind wall time, which rejects every current window with Custom(6010)
# ("window start must be at or before now") and can only be cleared by resetting
# the ledger.
ALLOW_MINT_FAILURE="${ALLOW_MINT_FAILURE:-0}"
assert_mint_health() {
    local lines confirmed failed submitted
    [ "$HAVE_DOCKER" = "1" ] || { warn "mint health: docker unavailable — SKIP"; return 0; }
    docker inspect "$AGG_CONTAINER" >/dev/null 2>&1 || { warn "mint health: $AGG_CONTAINER not found — SKIP"; return 0; }

    lines=$(docker logs --since 3m "$AGG_CONTAINER" 2>&1 \
            | grep -Eo 'batch surplus mint: [0-9]+ confirmed, [0-9]+ failed of [0-9]+ submitted' | tail -5)
    if [ -z "$lines" ]; then
        warn "mint health: no surplus-mint batch ran in the last 3m — nothing to judge (a 15-min bin must close first)"
        return 0
    fi
    confirmed=$(printf '%s\n' "$lines" | awk '{s+=$4} END{print s+0}')
    failed=$(printf   '%s\n' "$lines" | awk '{s+=$6} END{print s+0}')
    submitted=$(printf '%s\n' "$lines" | awk '{s+=$9} END{print s+0}')
    printf '%s\n' "$lines" | sed 's/^/    /'

    if [ "$confirmed" -gt 0 ] && [ "$failed" -eq 0 ]; then
        ok "surplus mint healthy: $confirmed confirmed / $submitted submitted"
        return 0
    fi
    if [ "$confirmed" -gt 0 ]; then
        warn "surplus mint DEGRADED: $confirmed confirmed but $failed failed of $submitted submitted"
        return 0
    fi
    # Nothing confirmed. Surface the on-chain cause — chain-bridge now carries the
    # program's error code (e.g. Custom 6010), so name it instead of "an error".
    local why
    # Match BOTH message shapes: "landed with on-chain error {json}" carries the
    # program's error code (chain-bridge b129431 onward), while the older
    # "landed with an on-chain error" says only that something failed. A stack
    # running a pre-b129431 image still reports the useless form, so accept it
    # rather than printing nothing at all.
    why=$(docker logs --since 3m "$CHAIN_BRIDGE_CONTAINER" 2>&1 \
          | grep -Eo 'landed with (an )?on-chain error[^;]*' | tail -1)
    err "surplus mint BROKEN: 0 confirmed of $submitted submitted ($failed failed)"
    [ -n "$why" ] && err "  on-chain cause: $why"
    err "  the trade matched, but no energy was minted — settlement to chain is NOT working"
    if [ "$ALLOW_MINT_FAILURE" = "1" ]; then
        warn "ALLOW_MINT_FAILURE=1 — recording the breakage but not failing the suite"
        return 0
    fi
    err "  set ALLOW_MINT_FAILURE=1 to accept this knowingly (e.g. validator clock drift)"
    FAILED=1
    return 1
}

FAILED=0

# ---------------------------------------------------------------------------
step "0) Pick real sim meters for telemetry attribution"
pick_sim_meters

step "1) Onboard PROSUMER (seller) + add meter"
onboard prosumer "${PROSUMER_SIM_CANDIDATES:-}" || { err "prosumer onboarding failed"; exit 1; }
PROSUMER_USER="$USERNAME"; PROSUMER_WALLET="$WALLET"; PROSUMER_TOKEN="$TOKEN"
PROSUMER_METER_ID="$METER_ID"; PROSUMER_SERIAL="$SERIAL"; PROSUMER_REAL="$REAL_MATCH"

step "2) Onboard CONSUMER (buyer) + add meter"
onboard consumer "${CONSUMER_SIM_CANDIDATES:-}" || { err "consumer onboarding failed"; exit 1; }
CONSUMER_USER="$USERNAME"; CONSUMER_WALLET="$WALLET"; CONSUMER_TOKEN="$TOKEN"
CONSUMER_METER_ID="$METER_ID"; CONSUMER_SERIAL="$SERIAL"

step "3) Prosumer proves REAL surplus (signed GENERATION telemetry)"
# Runs for an invented serial too, NOT only a claimed sim device. `send_surplus`
# builds its own `MeterKey(serial)` — the deterministic sha256("SECRET:serial")
# Ed25519 key — and calls register_pubkeys_redis/register_enckeys_redis for that
# serial before sending, so it manufactures the whole signed frame itself. It
# never reads the sim's device list. The old `PROSUMER_REAL = 1` guard therefore
# gated a capability the fallback path already had, and its cost was severe: a
# meter is one-owner, so every prior run permanently consumed a pool device, and
# once the 20 has_solar candidates were gone (82 of them claimed by 2026-08-02)
# EVERY subsequent run fell back, skipped the surplus, and then died at 3b —
# looking like the verified-meter feature was broken when it was the harness
# running out of a resource it never needed.
if [ "${SKIP_SURPLUS:-0}" = "1" ]; then
    info "SKIP_SURPLUS=1 — skipping telemetry proof, going straight to orders"
else
    [ "$PROSUMER_REAL" = "1" ] \
        || info "prosumer serial is this run's own (no pool device claimed) — signing telemetry for it directly"
    send_surplus "$PROSUMER_SERIAL"
fi

step "3b) Verify the prosumer's meter [HARD GATE — a sell is refused without it]"
# Registration claims a serial; verification proves the device behind it. Trading
# returns 403 on a sell from a seller with no verified meter, so this is now a
# prerequisite of step 4, not an optional extra.
if ! verify_meter "$PROSUMER_TOKEN" "$PROSUMER_SERIAL"; then
    err "prosumer meter unverified — the SELL in step 4 would be refused 403; aborting"
    exit 1
fi

step "4) Trade — prosumer SELL x consumer BUY (zone $ZONE_ID)"
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

step "5) Wait ${SETTLE_WAIT}s for CDA matcher to fill the crossed book [HARD GATE]"
sleep "$SETTLE_WAIT"
trades=$(curl -sk -m15 "${GW}/api/v1/trades?limit=20" -H "Authorization: Bearer $PROSUMER_TOKEN")
echo "$trades" | jq '{total_count, total, sample: (.trades[0] // null)}' 2>/dev/null || echo "$trades" | head -c300
matched=$(echo "$trades" | jq --arg s "$sid" --arg b "$bid" \
    '[.trades[]? | select((.buy_order_id==$b) or (.sell_order_id==$s) or (.maker_order_id==$s) or (.taker_order_id==$b))] | length' 2>/dev/null)
printf '\n'
if [ "${matched:-0}" -gt 0 ]; then
    ok "P2P MATCH CONFIRMED: prosumer sell=$sid / consumer buy=$bid produced $matched trade(s)."
else
    err "no trade references sell=$sid / buy=$bid after ${SETTLE_WAIT}s — matcher may still be draining; raise SETTLE_WAIT."
    FAILED=1
fi

step "6) Settlement evidence + surplus-mint health"
grep_recent_log "$AGG_CONTAINER" "completed billing bins|settlement" "settlement"
assert_mint_health

# ---------------------------------------------------------------------------
step "Summary"
info "prosumer=$PROSUMER_USER wallet=$PROSUMER_WALLET meter=$PROSUMER_METER_ID serial=$PROSUMER_SERIAL"
info "consumer=$CONSUMER_USER wallet=$CONSUMER_WALLET meter=$CONSUMER_METER_ID serial=$CONSUMER_SERIAL"
if [ "$FAILED" = "0" ]; then
    ok "SUITE 97 PASS — P2P prosumer→consumer trade filled end-to-end."
    exit 0
else
    err "SUITE 97 FAIL — see the failing step above (5 = match not confirmed, 6 = surplus mint broken)."
    exit 1
fi
