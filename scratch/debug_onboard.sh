#!/bin/bash
API_URL="http://localhost:4010"
TIMESTAMP=$(date +%s)
EMAIL="onboard_test_${TIMESTAMP}@grx.test"
USERNAME="user_onboard_${TIMESTAMP}"
PASSWORD="GridTokenX-$2024-@Secret"

echo "Registering..."
REG=$(curl -s -X POST "$API_URL/api/v1/auth/register" -H "Content-Type: application/json" -H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" -d "{\"username\":\"$USERNAME\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}")
ID=$(echo $REG | jq -r .id)
echo "ID: $ID"

echo "Verifying..."
TOKEN=$(docker exec -i gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx -t -c "SELECT email_verification_token FROM users WHERE id = '$ID';" | tr -d '[:space:]')
curl -s -X GET "$API_URL/api/v1/auth/verify?token=$TOKEN" -H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" > /dev/null

echo "Logging in..."
LOGIN=$(curl -s -X POST "$API_URL/api/v1/auth/login" -H "Content-Type: application/json" -H "x-gridtokenx-role: api-gateway" -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")
JWT=$(echo $LOGIN | jq -r .access_token)
echo "JWT: ${JWT:0:20}..."

echo "Onboarding..."
ONBOARD=$(curl -v -X POST "$API_URL/api/v1/identity/onboard" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{
        \"user_type\": \"Prosumer\",
        \"lat_e7\": 13736717,
        \"long_e7\": 100523186,
        \"h3_index\": \"894110000000000\",
        \"shard_id\": 1
    }")
echo "Response: $ONBOARD"
