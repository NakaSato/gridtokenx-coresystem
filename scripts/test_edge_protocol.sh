#!/usr/bin/env bash
#
# test_edge_protocol.sh — Edge/DLMS protocol smoke test against the Aggregator
# Bridge IoT gateway (the script behind `just test-edge`).
#
# The IoT gateway terminates TLS and (when IOT_GATEWAY_TLS_CLIENT_CA is set)
# requires a client cert — so this talks HTTPS + mTLS. It also auto-detects
# AGGREGATOR_REQUIRE_SECURE ("secure mode") by probing, and asserts the matching
# behaviour either way:
#
#   secure OFF                          secure ON (AGGREGATOR_REQUIRE_SECURE=true)
#   ----------                          -----------------------------------------
#   1 health 200 "iot-gateway"          1 health 200 "iot-gateway"
#   2 simulator frame  → accepted       2 simulator frame  → refused  (bypass off)
#   3 bad signature    → rejected       3 plaintext dlms    → 426      (needs dlms-enc)
#   4 signed dlms      → accepted       4 batch path        → 426
#     (needs python3 + cryptography)
#
# Contract (verified against source — handlers.rs, infra/crypto.rs):
#   host port    IOT_GATEWAY_PORT host-mapped (compose: 4030 → container 4010)
#   transport    HTTPS, mTLS client cert verified against ca.crt
#   auth header  X-API-KEY  (GRIDTOKENX_API_KEYS / IAM)
#   route        POST /v1/private-network/ingest[/batch]
#   body         {"protocol","device_id","payload":{...}}
#   sign string  "{device_id}:{kwh}:{timestamp_ms}"   (canonical_sign_value)
#   signature    base58(ed25519_sign(sign_string)) in payload.signature
#   pubkey       redis  gridtokenx:devices:{device_id}:pubkey = 64-char hex
#
# Config (env overrides):
#   GATEWAY_URL   default https://127.0.0.1:4030
#   API_KEY       default engineering-department-api-key-2025
#   CERT_DIR      default infra/certs           (ca.crt + clients/<name>.{crt,key})
#   CLIENT_NAME   default smartmeter-simulator  (which clients/<name> cert to present)
#   REDIS_CLI     default "docker exec -i gridtokenx-redis redis-cli"
#   SECURE_MODE   "auto" (default) | 1 | 0      (override the probe)
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2   # repo root (script lives in scripts/)

GATEWAY_URL="${GATEWAY_URL:-https://127.0.0.1:4030}"
API_KEY="${API_KEY:-engineering-department-api-key-2025}"
CERT_DIR="${CERT_DIR:-infra/certs}"
CLIENT_NAME="${CLIENT_NAME:-smartmeter-simulator}"
REDIS_CLI="${REDIS_CLI:-docker exec -i gridtokenx-redis redis-cli}"
SECURE_MODE="${SECURE_MODE:-auto}"

CA="${CERT_DIR}/ca.crt"
CLIENT_CRT="${CERT_DIR}/clients/${CLIENT_NAME}.crt"
CLIENT_KEY="${CERT_DIR}/clients/${CLIENT_NAME}.key"

PASS=0; FAIL=0; SKIP=0
c_g=$'\033[0;32m'; c_r=$'\033[0;31m'; c_y=$'\033[0;33m'; c_d=$'\033[2m'; c_o=$'\033[0m'
pass() { PASS=$((PASS+1)); echo "${c_g}✅ PASS${c_o} $1"; }
fail() { FAIL=$((FAIL+1)); echo "${c_r}❌ FAIL${c_o} $1"; }
skip() { SKIP=$((SKIP+1)); echo "${c_y}⏭️  SKIP${c_o} $1"; }
info() { echo "${c_d}   $1${c_o}"; }

# Curl with TLS + mTLS when the certs are present (falls back to -k for the
# self-signed dev cert; adds the client cert only if it exists).
CURL_TLS=(--cacert "$CA" -k)
[ -f "$CLIENT_CRT" ] && [ -f "$CLIENT_KEY" ] && CURL_TLS+=(--cert "$CLIENT_CRT" --key "$CLIENT_KEY")

# POST a JSON body to a route; echo the HTTP status code.
post() {  # post <route> <json>
  curl -sS "${CURL_TLS[@]}" -o /dev/null -w '%{http_code}' \
    -X POST "${GATEWAY_URL}$1" \
    -H 'Content-Type: application/json' -H "X-API-KEY: ${API_KEY}" \
    --data-binary "$2" 2>/dev/null
}
# shellcheck disable=SC2086  # REDIS_CLI is a multi-word command; word-splitting is intended.
redis() { ${REDIS_CLI} "$@" 2>/dev/null; }
is_2xx() { [ "${1:-0}" -ge 200 ] 2>/dev/null && [ "${1:-0}" -lt 300 ] 2>/dev/null; }
is_reject() { case "${1:-}" in 401|403|426) return 0;; *) return 1;; esac; }  # auth/secure rejects, NOT 404/5xx
now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
iso_to_ms() { # parse our own "%Y-%m-%dT%H:%M:%SZ" → epoch ms (macOS or GNU date)
  local s; s=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null)
  echo "$(( ${s:-0} * 1000 ))"
}

sim_frame() { echo "{\"protocol\":\"simulator\",\"device_id\":\"$1\",\"payload\":{\"kwh\":10.0,\"timestamp\":\"$(now_iso)\",\"zone_code\":\"1\"}}"; }

echo "── Edge protocol test ─ ${GATEWAY_URL} ──"
[ -f "$CLIENT_CRT" ] && info "mTLS client cert: ${CLIENT_CRT}" || info "no client cert at ${CLIENT_CRT} — server-TLS only"

# ---------------------------------------------------------------------------
# 1. Health — must be the IoT gateway (host :4010 is IAM; assert the service name)
# ---------------------------------------------------------------------------
h=$(curl -sS "${CURL_TLS[@]}" -w '\n%{http_code}' "${GATEWAY_URL}/health" 2>/dev/null)
code="${h##*$'\n'}"; body="${h%$'\n'*}"
if [ "$code" = "200" ] && printf '%s' "$body" | grep -q 'iot-gateway'; then
  pass "health → 200 (gridtokenx-iot-gateway)"
else
  fail "health → expected 200/iot-gateway, got ${code:-no-response}"
  info "body: ${body:-<none>} — is the bridge up + TLS/mTLS certs right? (${GATEWAY_URL})"
  echo "──────────────────────────────────────────────"
  echo "Edge protocol: aborting — gateway unreachable"
  exit 1
fi

# ---------------------------------------------------------------------------
# Detect secure mode: a simulator frame is accepted (2xx) only when secure off.
# ---------------------------------------------------------------------------
probe=$(post /v1/private-network/ingest "$(sim_frame EDGE-PROBE-000)")
if [ "$SECURE_MODE" = "auto" ]; then
  if is_2xx "$probe"; then SECURE_MODE=0; else SECURE_MODE=1; fi
fi
info "secure mode: ${SECURE_MODE} (probe status ${probe})"

# ---------------------------------------------------------------------------
# 2. Simulator unsigned frame
# ---------------------------------------------------------------------------
code=$(post /v1/private-network/ingest "$(sim_frame EDGE-SIM-001)")
if [ "$SECURE_MODE" = "1" ]; then
  is_reject "$code" && pass "secure: simulator bypass refused → ${code}" \
                    || fail "secure: simulator should be refused (401/403/426), got ${code}"
else
  is_2xx "$code" && pass "simulator unsigned ingest → ${code} accepted" \
                 || fail "simulator ingest → expected 2xx, got ${code}"
fi

# ---------------------------------------------------------------------------
# 3. Plaintext dlms with a BAD signature must be rejected (fail-closed).
#    secure ON  → 426 (dlms-enc required, before sig check)
#    secure OFF → 401/403 (signature verification fails)
# ---------------------------------------------------------------------------
BAD=EDGE-BADSIG-001
redis SET "gridtokenx:devices:${BAD}:pubkey" "$(printf '03%.0s' $(seq 1 32))" >/dev/null
bad_body="{\"protocol\":\"dlms\",\"device_id\":\"${BAD}\",\"payload\":{\"kwh\":5.0,\"timestamp\":\"$(now_iso)\",\"signature\":\"3yZe7d8j9kQwErTyUiOpAsDfGhJkLzXcVbNm1234567890aBcDeFgHJkLmNpQrStUv\",\"zone_code\":\"1\"}}"
code=$(post /v1/private-network/ingest "$bad_body")
is_reject "$code" && pass "bad-signature dlms frame rejected → ${code} (fail-closed)" \
                  || fail "bad-signature frame should be rejected (401/403/426), got ${code}"
redis DEL "gridtokenx:devices:${BAD}:pubkey" >/dev/null

# ---------------------------------------------------------------------------
# 4a. (secure OFF) Signed dlms happy-path — needs python3 + cryptography.
# 4b. (secure ON)  Batch path must be refused with 426.
# ---------------------------------------------------------------------------
if [ "$SECURE_MODE" = "1" ]; then
  code=$(post /v1/private-network/ingest/batch \
    "{\"protocol\":\"simulator\",\"readings\":[{\"device_id\":\"EDGE-SIM-002\",\"kwh\":1.0,\"timestamp\":\"$(now_iso)\"}]}")
  [ "$code" = "426" ] && pass "secure: batch ingest refused → 426" \
                      || fail "secure: batch should be 426, got ${code}"
else
  SM=EDGE-SIGNED-001; KWH=42.5; TS="$(now_iso)"; TS_MS="$(iso_to_ms "$TS")"
  signed=""
  command -v python3 >/dev/null 2>&1 && signed=$(SIGN_STR="${SM}:${KWH}:${TS_MS}" python3 - <<'PY' 2>/dev/null
import os, sys
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
except Exception:
    sys.exit(3)
def b58(b):
    a="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; n=int.from_bytes(b,"big"); o=""
    while n>0: n,r=divmod(n,58); o=a[r]+o
    return "1"*(len(b)-len(b.lstrip(b"\x00")))+(o or "1")
sk=Ed25519PrivateKey.generate()
pk=sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
print(pk.hex()+" "+b58(sk.sign(os.environ["SIGN_STR"].encode())))
PY
)
  if [ -n "$signed" ]; then
    redis SET "gridtokenx:devices:${SM}:pubkey" "${signed%% *}" >/dev/null
    code=$(post /v1/private-network/ingest \
      "{\"protocol\":\"dlms\",\"device_id\":\"${SM}\",\"payload\":{\"kwh\":${KWH},\"timestamp\":\"${TS}\",\"signature\":\"${signed##* }\",\"zone_code\":\"1\"}}")
    is_2xx "$code" && pass "signed dlms frame accepted → ${code}" \
                   || fail "signed dlms frame → expected 2xx, got ${code} (sign str ${SM}:${KWH}:${TS_MS})"
    redis DEL "gridtokenx:devices:${SM}:pubkey" >/dev/null
  else
    skip "signed happy-path (needs python3 + 'cryptography': pip install cryptography)"
  fi
fi

echo "──────────────────────────────────────────────"
echo "Edge protocol: ${c_g}${PASS} passed${c_o}, ${c_r}${FAIL} failed${c_o}, ${c_y}${SKIP} skipped${c_o}"
[ "$FAIL" -eq 0 ]
