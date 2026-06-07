#!/usr/bin/env bash
# Smoke test Phases 1-5 trading REST endpoints via APISIX gateway.
# Dev only. Mints an HS256 JWT matching the apisix.yaml dev consumer
# (key/iss=gridtokenx-iam-service, dev secret). All calls go through the gateway.
set -uo pipefail

GW="${GW:-https://apisix.gridtokenx-coresystem.orb.local}"
ISS="gridtokenx-iam-service"
SECRET="dev-jwt-secret-key-minimum-32-characters-long-for-development-2025"
SUB="${SUB:-215a2a65-f187-4b3d-a02d-f0073a502309}"  # real users.id (FK for recurring/alerts)

# --- mint JWT (HS256: iss + sub + exp) ---
TOKEN="$(python3 - "$ISS" "$SUB" "$SECRET" <<'PY'
import base64, hmac, hashlib, json, sys, time
iss, sub, secret = sys.argv[1], sys.argv[2], sys.argv[3]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
seg = lambda o: b64(json.dumps(o, separators=(",", ":")).encode())
head = seg({"alg": "HS256", "typ": "JWT"})
body = seg({"iss": iss, "sub": sub, "iat": int(time.time()), "exp": int(time.time()) + 3600})
msg = f"{head}.{body}".encode()
sig = b64(hmac.new(secret.encode(), msg, hashlib.sha256).digest())
print(f"{head}.{body}.{sig}")
PY
)"
[ -n "$TOKEN" ] || { echo "FAIL: could not mint JWT"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN")

PASS=0; FAIL=0
# hit METHOD PATH EXPECTED [data]
hit() {
  local method="$1" path="$2" expect="$3" data="${4:-}"
  local args=(-sk -m 10 -o /tmp/smoke_body -w "%{http_code}" -X "$method" "${AUTH[@]}")
  [ -n "$data" ] && args+=(-H "Content-Type: application/json" -d "$data")
  local code; code="$(curl "${args[@]}" "$GW$path")"
  if [[ " $expect " == *" $code "* ]]; then
    printf "  ✅ %-6s %-45s %s\n" "$method" "$path" "$code"; PASS=$((PASS+1))
  else
    printf "  ❌ %-6s %-45s got %s want %s\n" "$method" "$path" "$code" "$expect"
    head -c 200 /tmp/smoke_body; echo; FAIL=$((FAIL+1))
  fi
}

echo "Gateway: $GW   sub: $SUB"
echo "== Phase 1 — markets reads =="
hit GET /api/v1/markets/config 200
hit GET /api/v1/markets/p2p/market-prices 200
hit GET /api/v1/markets/matching-status 200
echo "== Phase 2 — settlement + orderbook =="
hit GET /api/v1/markets/settlement-stats 200
hit GET /api/v1/markets/orderbook 200
echo "== Phase 3 — trades =="
hit GET /api/v1/trades 200
hit GET /api/v1/trades/export 200
echo "== Phase 4 — price-alerts CRUD =="
ALERT='{"symbol":"GRID","target_price":"0.25","condition":"above"}'
CODE_AL="$(curl -sk -m10 -o /tmp/al "${AUTH[@]}" -H 'Content-Type: application/json' -d "$ALERT" -w '%{http_code}' "$GW/api/v1/price-alerts")"
echo "  create price-alert -> $CODE_AL"; cat /tmp/al; echo
AL_ID="$(python3 -c 'import json,sys;print(json.load(open("/tmp/al")).get("id",""))' 2>/dev/null)"
hit GET /api/v1/price-alerts 200
[ -n "$AL_ID" ] && hit DELETE "/api/v1/price-alerts/$AL_ID" "200 204"
echo "== Phase 5 — recurring CRUD + pause/resume =="
REC='{"side":"buy","energy_amount":"10.5","max_price_per_kwh":"0.20","interval_type":"daily","interval_value":1}'
CODE_RC="$(curl -sk -m10 -o /tmp/rc "${AUTH[@]}" -H 'Content-Type: application/json' -d "$REC" -w '%{http_code}' "$GW/api/v1/orders/recurring")"
echo "  create recurring -> $CODE_RC"; cat /tmp/rc; echo
RC_ID="$(python3 -c 'import json,sys;print(json.load(open("/tmp/rc")).get("id",""))' 2>/dev/null)"
hit GET /api/v1/orders/recurring 200
if [ -n "$RC_ID" ]; then
  hit GET "/api/v1/orders/recurring/$RC_ID" 200
  hit POST "/api/v1/orders/recurring/$RC_ID/pause" "200 204"
  hit POST "/api/v1/orders/recurring/$RC_ID/resume" "200 204"
  hit DELETE "/api/v1/orders/recurring/$RC_ID" "200 204"
fi

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
