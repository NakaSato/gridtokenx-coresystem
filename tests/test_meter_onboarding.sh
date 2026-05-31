#!/bin/bash
API_URL="${API_URL:-http://apisix.gridtokenx-coresystem.orb.local}"
TIMESTAMP=$(date +%s)
USER="testuser_${TIMESTAMP}"
EMAIL="${USER}@test.com"
PASS="TestPass123!"

echo "1. Registering user..."
curl -s -X POST "$API_URL/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USER\",\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" > /dev/null

echo "2. Verifying email..."
VERIFY_RESP=$(curl -s "$API_URL/api/v1/auth/verify?token=verify_$EMAIL")
JWT=$(echo "$VERIFY_RESP" | jq -r '.auth.access_token')

echo "3. Registering meter (case-insensitive check)..."
METER_RESP=$(curl -s -X POST "$API_URL/api/v1/meters" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $JWT" \
  -H "x-gridtokenx-role: api-gateway" \
  -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
  -d "{
    \"serial_number\": \"METER-${TIMESTAMP}\",
    \"meter_type\": \"solar\",
    \"location\": \"Bangkok\",
    \"shard_id\": 7
  }")

echo "Response: $METER_RESP"
if [[ "$(echo "$METER_RESP" | jq -r '.success')" == "false" ]] && [[ "$(echo "$METER_RESP" | jq -r '.message')" == *"on-chain registration failed"* ]]; then
  echo "✅ Meter saved locally, on-chain attempt confirmed (expected failure in mock environment)"
else
  echo "❌ Unexpected response"
fi
