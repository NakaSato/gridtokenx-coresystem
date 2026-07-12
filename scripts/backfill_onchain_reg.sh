#!/usr/bin/env bash
# Backfill on-chain Registry PDA for every registered user. The main register run
# lost the validator mid-way, so ~54 users have blockchain_status != confirmed and
# no PDA — which makes trade settlement skip them ("no on-chain PDA"). This re-runs
# step 5 (POST /me/registration) now that the validator is back, idempotently.
set -uo pipefail
CREDS="${1:-$(cd "$(dirname "$0")" && pwd)/registered_users_meters.txt}"
IAM_BASE="${IAM_BASE:-http://localhost:${IAM_HTTP_PORT:-4010}}"
GW_SECRET="${GATEWAY_SECRET:-gridtokenx-gateway-secret-2025}"
LAT="${LAT_E7:-13750000}"; LONG="${LONG_E7:-100500000}"
gw=(-H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: $GW_SECRET")
ok=0 proc=0 fail=0 n=0
{
  read -r _h
  while IFS=$'\t' read -r username password email wallet serial meter_id user_id; do
    [ -z "$username" ] && continue
    n=$((n+1))
    tok=$(curl -s -m15 -X POST "$IAM_BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
          -d "{\"username\":\"$username\",\"password\":\"$password\"}" | jq -r '.access_token // .data.auth.access_token // empty')
    [ -z "$tok" ] && { echo "✘ login $username"; fail=$((fail+1)); continue; }
    st=$(curl -s -m30 -X POST "$IAM_BASE/api/v1/me/registration" "${gw[@]}" \
         -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
         -d "{\"user_type\":\"prosumer\",\"location\":{\"lat_e7\":$LAT,\"long_e7\":$LONG}}" \
         | jq -r '.status // "err"')
    case "$st" in
      processing|confirmed) ok=$((ok+1)) ;;
      *) fail=$((fail+1)); echo "✘ $username -> $st" ;;
    esac
    [ $((n % 10)) -eq 0 ] && echo "… $n done (ok=$ok fail=$fail)"
  done
} < "$CREDS"
echo "backfill: $ok ok / $fail fail of $n"
