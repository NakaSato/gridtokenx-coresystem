#!/usr/bin/env bash
# GridTokenX Platform - End-to-End Integration Test via APISIX Gateway
# Targets Port 4001

BASE="http://apisix.gridtokenx-coresystem.orb.local"
TS=$(date +%s)
USER="int_user_${TS}"
EMAIL="${USER}@gridtokenx.com"
PASS="IntegrationPass123!"

SUCCESS_COUNT=0; FAIL_COUNT=0

print_section() {
  echo -e "\n\033[1;34m=== $1 ===\033[0m"
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$(echo "$actual" | tr '[:upper:]' '[:lower:]')" == *"$(echo "$expected" | tr '[:upper:]' '[:lower:]')"* ]]; then
    echo -e "✅ $name"
    ((SUCCESS_COUNT++))
  else
    echo -e "❌ $name \n   Expected: $expected\n   Actual: $actual"
    ((FAIL_COUNT++))
  fi
}

# 1. PUBLIC ENDPOINTS
print_section "Testing Public Endpoints (via Simulator Proxy)"

R=$(curl -s "$BASE/api/v1/public/grid-status")
check "GET /api/v1/public/grid-status" "running" "$R"

R=$(curl -s "$BASE/api/v1/public/grid-topology")
check "GET /api/v1/public/grid-topology" "topology" "$R"

R=$(curl -s "$BASE/api/v1/public/meters")
check "GET /api/v1/public/meters" "meters" "$R"

# 2. AUTH FLOW
print_section "Testing Authentication (via IAM Service)"

R=$(curl -s -X POST "$BASE/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USER\",\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")
check "POST /api/v1/auth/register" "\"id\":" "$R"

# Auto-verify in TEST_MODE
curl -s "$BASE/api/v1/auth/verify?token=verify_$EMAIL" > /dev/null

R=$(curl -s -X POST "$BASE/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}")
check "POST /api/v1/auth/login" "access_token" "$R"
TOKEN=$(echo "$R" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "Critical: Failed to obtain token. Aborting remaining tests."
  exit 1
fi

# 3. USER DATA
print_section "Testing User Resources (via IAM & Trading)"

R=$(curl -s "$BASE/api/v1/me" -H "Authorization: Bearer $TOKEN")
check "GET /api/v1/me (IAM)" "\"username\":\"$USER\"" "$R"

R=$(curl -s "$BASE/api/v1/analytics/stats" -H "Authorization: Bearer $TOKEN")
check "GET /api/v1/analytics/stats (Trading Mock)" "total_traded_kwh" "$R"

# 4. TRADING & MARKETS
print_section "Testing Trading Resources (via Trading Service)"

R=$(curl -s "$BASE/api/v1/markets/stats" -H "Authorization: Bearer $TOKEN")
check "GET /api/v1/markets/stats" "avg_price_24h" "$R"

R=$(curl -s "$BASE/api/v1/orders" -H "Authorization: Bearer $TOKEN")
check "GET /api/v1/orders" "pagination" "$R"

R=$(curl -s "$BASE/api/v1/carbon/balance" -H "Authorization: Bearer $TOKEN")
check "GET /api/v1/carbon/balance" "total_credits" "$R"

# 5. NOTIFICATIONS
print_section "Testing Notification Resources (via Noti Service)"

R=$(curl -s "$BASE/api/v1/notifications" -H "Authorization: Bearer $TOKEN")
check "GET /api/v1/notifications" "unread_count" "$R"

# SUMMARY
print_section "Verification Summary"
echo "Results: $SUCCESS_COUNT passed, $FAIL_COUNT failed out of $((SUCCESS_COUNT+FAIL_COUNT)) tests"

[[ $FAIL_COUNT -eq 0 ]] && exit 0 || exit 1
