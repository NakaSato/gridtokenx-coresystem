#!/bin/bash
set -e

GATEWAY_URL="http://localhost:4001"
# We need a valid JWT for testing. In a real test, we'd register/login first.
# For now, this script outlines the endpoints to verify.

echo "🔍 Verifying GridTokenX Modernized API Stack (via APISIX)"
echo "--------------------------------------------------------"

# 1. IAM Service
echo "Checking IAM Identity..."
curl -s -X GET "$GATEWAY_URL/api/v1/users/me" \
  -H "Authorization: Bearer $TEST_JWT" | jq .

echo "Checking IAM Wallets..."
curl -s -X GET "$GATEWAY_URL/api/v1/users/me/wallets" \
  -H "Authorization: Bearer $TEST_JWT" | jq .

# 2. Trading Service
echo "Checking Trading Orders..."
curl -s -X GET "$GATEWAY_URL/api/v1/users/me/orders" \
  -H "Authorization: Bearer $TEST_JWT" | jq .

echo "Checking Trading Carbon Balance..."
curl -s -X GET "$GATEWAY_URL/api/v1/users/me/carbon" \
  -H "Authorization: Bearer $TEST_JWT" | jq .

# 3. Notification Service
echo "Checking Notifications..."
curl -s -X GET "$GATEWAY_URL/api/v1/users/me/notifications" \
  -H "Authorization: Bearer $TEST_JWT" | jq .

echo "--------------------------------------------------------"
echo "✅ Verification script completed."
