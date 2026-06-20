#!/bin/bash
# GridTokenX - onboard-meter command
#
# Full prosumer onboarding, end to end, per user:
#   1. Register     POST /api/v1/auth/register            -> user_id
#   2. Verify email GET  /api/v1/auth/verify?token=verify_<email>
#   3. Login        POST /api/v1/auth/login               -> JWT
#   4. Link wallet  POST /api/v1/me/wallets         (real Solana keypair, primary)
#   5. On-chain     POST /api/v1/me/registration (Registry PDA via Chain Bridge)
#   6. Add meter    deterministic Ed25519 device key -> Redis pubkey + meter->user map
#   7. Telemetry    POST /v1/private-network/ingest       (signed DLMS generation reading)
#   8. Verify       reading accepted (202) + on-chain gen_mint record amount
#   9. Save         append username,password,email,wallet_address to a txt file
#
# Usage:
#   ./app.sh onboard-meter [count] [output_file] [gen_kwh]
#     count        number of users to onboard         (default 1)
#     output_file  credentials TSV                     (default scripts/onboarded_users.txt)
#     gen_kwh      generated energy per reading        (default 5)
#
# Env overrides: IAM_BASE, REDIS_CONTAINER, SIM_CONTAINER (default gridtokenx-smartmeter-simulator),
#   NETWORK (docker net, default gridtokenx-coresystem_gridtokenx-network), GATEWAY_SECRET,
#   DEFAULT_PASS, RPC_URL, ENERGY_TOKEN_PROGRAM_ID, API_KEY (ingest key), KEY_SECRET (sim key secret).

cmd_onboard_meter() {
    show_banner
    local count="${1:-1}" outfile="${2:-$PROJECT_ROOT/scripts/onboarded_users.txt}" gen="${3:-5}"

    command -v jq           >/dev/null 2>&1 || { log_error "jq required";           return 1; }
    command -v curl         >/dev/null 2>&1 || { log_error "curl required";         return 1; }
    command -v solana-keygen>/dev/null 2>&1 || { log_error "solana-keygen required";return 1; }
    _pm_defaults

    local sim="${SIM_CONTAINER:-gridtokenx-smartmeter-simulator}"
    local net="${NETWORK:-gridtokenx-coresystem_gridtokenx-network}"
    local rpc="${RPC_URL:-http://localhost:8899}"
    local energy_prog="${ENERGY_TOKEN_PROGRAM_ID:-6FZKcVKCLFSNLMxypFJGU4K14xUBnxNW9VAuKGhmqjGX}"
    local api_key="${API_KEY:-${GRIDTOKENX_API_KEYS%%,*}}"; api_key="${api_key:-engineering-department-api-key-2025}"
    local key_secret="${KEY_SECRET:-gridtokenx-sim}"
    local gw=(-H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: $PM_GW_SECRET")

    if ! docker exec "$sim" true 2>/dev/null; then
        log_error "sim container '$sim' not running (needed for Ed25519 signing). Set SIM_CONTAINER."
        return 1
    fi
    if ! curl -fsS -m 5 "$PM_BASE/health" >/dev/null 2>&1; then
        log_error "IAM not reachable at $PM_BASE/health"
        return 1
    fi

    # closed window (now - 20 min) so the reading settles on the next tick
    local ts_ms; ts_ms=$(( ( $(date +%s) - 1200 ) * 1000 ))

    [ -f "$outfile" ] || printf 'username\tpassword\temail\twallet_address\tmeter_id\tuser_id\n' > "$outfile"

    local meters=() wallets=() i
    for i in $(seq 1 "$count"); do
        local stamp; stamp=$(date +%s%N)
        local username="onboard_${stamp}" email="onboard_${stamp}@example.com" password="$PM_PASS"
        echo ""; log_info "user $i/$count: $username"

        # 1. register
        local reg uid
        reg=$(curl -s -X POST "$PM_BASE/api/v1/auth/register" -H 'Content-Type: application/json' \
              -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$password\"}")
        uid=$(echo "$reg" | jq -r '.id // .data.id // empty')
        [ -z "$uid" ] && { log_error "register failed: $(echo "$reg"|head -c160)"; continue; }
        log_success "registered user_id=$uid"

        # 2. verify  3. login
        curl -s "$PM_BASE/api/v1/auth/verify?token=verify_${email}" >/dev/null
        local token
        token=$(curl -s -X POST "$PM_BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
                -d "{\"username\":\"$username\",\"password\":\"$password\"}" \
                | jq -r '.access_token // .data.auth.access_token // empty')
        [ -z "$token" ] && { log_error "login failed"; continue; }
        local auth=(-H "Authorization: Bearer $token")

        # 4. link real wallet
        local kf wallet; kf=$(mktemp)
        solana-keygen new --no-bip39-passphrase --silent --force --outfile "$kf" >/dev/null 2>&1
        wallet=$(solana-keygen pubkey "$kf"); rm -f "$kf"
        curl -s -X POST "$PM_BASE/api/v1/me/wallets" "${gw[@]}" "${auth[@]}" \
             -H 'Content-Type: application/json' \
             -d "{\"wallet_address\":\"$wallet\",\"label\":\"Primary\",\"is_primary\":true}" >/dev/null
        log_success "linked wallet $wallet"

        # 5. on-chain
        local onb status
        onb=$(curl -s -X POST "$PM_BASE/api/v1/me/registration" "${gw[@]}" "${auth[@]}" \
              -H 'Content-Type: application/json' \
              -d "{\"user_type\":\"prosumer\",\"location\":{\"lat_e7\":$PM_LAT,\"long_e7\":$PM_LONG}}")
        status=$(echo "$onb" | jq -r '.status // "unknown"')
        log_info "on-chain status=$status"

        # 6. add meter: deterministic key -> pubkey + signed reading (via sim container crypto)
        local meter; meter=$(uuidgen | tr 'A-Z' 'a-z')
        local out pub body
        out=$(docker exec -e MID="$meter" -e TSMS="$ts_ms" -e GEN="$gen" -e SECRET="$key_secret" "$sim" \
            sh -c 'cat > /tmp/onb.py <<"PY"
import os, hashlib, json, base58
from datetime import datetime, timezone
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
mid=os.environ["MID"]; ts=int(os.environ["TSMS"]); gen=float(os.environ["GEN"]); sec=os.environ["SECRET"]
seed=hashlib.sha256(f"{sec}:{mid}".encode()).digest()
p=Ed25519PrivateKey.from_private_bytes(seed)
pub=p.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
net=round(gen,6)
r=lambda x: str(int(x)) if x==int(x) and abs(x)<1e16 else repr(x)
sig=base58.b58encode(p.sign(f"{mid}:{r(net)}:{ts}".encode())).decode()
iso=datetime.fromtimestamp(ts/1000, tz=timezone.utc).isoformat()
body={"protocol":"dlms","device_id":mid,"payload":{"1.1.1.8.0.255":0.0,"1.1.2.8.0.255":round(gen*1000,3),"kwh":net,"energy_generated":round(gen,6),"energy_consumed":0.0,"timestamp":iso,"signature":sig}}
print("PUBKEY="+pub); print("BODY="+json.dumps(body))
PY
uv run python /tmp/onb.py' 2>/dev/null)
        pub=$(echo "$out" | sed -n 's/^PUBKEY=//p')
        body=$(echo "$out" | sed -n 's/^BODY=//p')
        [ -z "$pub" ] || [ -z "$body" ] && { log_error "signing failed for meter $meter"; continue; }
        docker exec "$PM_REDIS" redis-cli SET "gridtokenx:devices:${meter}:pubkey" "$pub" >/dev/null
        docker exec "$PM_REDIS" redis-cli SET "gridtokenx:meters:${meter}:user_id" "$uid" >/dev/null
        # Mint recipient: the Aggregator Bridge resolve_wallet() reads
        # gridtokenx:meters:{serial}:wallet (Postgres fallback only resolves meters
        # that exist as a PG row, which these Redis-mapped meters do not). Without
        # this key surplus mints are skipped ("no wallet registered for meter ...").
        docker exec "$PM_REDIS" redis-cli SET "gridtokenx:meters:${meter}:wallet" "$wallet" >/dev/null
        log_success "meter $meter added (pubkey + owner + wallet)"

        # 7. send telemetry  8. verify accepted
        local resp http
        resp=$(docker run --rm --network "$net" curlimages/curl:latest -s -m10 \
               -X POST -H 'Content-Type: application/json' -H "X-API-KEY: $api_key" \
               -d "$body" -w '\n%{http_code}' http://aggregator-bridge:4010/v1/private-network/ingest 2>/dev/null)
        http=$(echo "$resp" | tail -1)
        if [ "$http" = "202" ] || [ "$http" = "200" ]; then
            log_success "telemetry accepted (HTTP $http, ${gen} kWh generated)"
        else
            log_warn "telemetry HTTP $http: $(echo "$resp"|head -1|head -c160)"
        fi

        # 9. save creds
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$username" "$password" "$email" "$wallet" "$meter" "$uid" >> "$outfile"
        meters+=("$meter"); wallets+=("$wallet")
    done

    # verify result: settle, then confirm GRID was minted to each user's wallet.
    # (Per-user wallet balance is the reliable signal — the energy-token gen_mint
    #  PDA is keyed by raw bytes that are awkward to query by memcmp.)
    if [ "${#wallets[@]}" -gt 0 ]; then
        local energy_mint="${ENERGY_TOKEN_MINT:-GktSLt9dFsTrSSxikMEQRNeQXhpN9NxUn4m9teixctVS}"
        echo ""; log_info "Waiting for settlement + verifying minted GRID per wallet..."
        local w deadline=$(( $(date +%s) + 600 )) minted=0
        for w in "${wallets[@]}"; do
            local bal=""
            while [ "$(date +%s)" -lt "$deadline" ]; do
                bal=$(curl -s -m8 "$rpc" -X POST -H 'Content-Type: application/json' \
                    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountsByOwner\",\"params\":[\"$w\",{\"mint\":\"$energy_mint\"},{\"encoding\":\"jsonParsed\"}]}" 2>/dev/null | \
                    python3 -c "import sys,json
v=json.load(sys.stdin).get('result',{}).get('value',[])
print(v[0]['account']['data']['parsed']['info']['tokenAmount']['uiAmountString'] if v else '')" 2>/dev/null)
                [ -n "$bal" ] && [ "$bal" != "0" ] && break
                sleep 10
            done
            if [ -n "$bal" ] && [ "$bal" != "0" ]; then log_success "wallet $w holds $bal GRID"; minted=$((minted+1));
            else log_warn "wallet $w not minted yet (check next settlement tick)"; fi
        done
        log_info "verified mints: $minted/${#wallets[@]}"
    fi

    log_success "Onboarded ${#meters[@]} user(s). Credentials saved to: $outfile"
}
