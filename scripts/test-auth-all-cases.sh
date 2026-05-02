#!/bin/bash

# GridTokenX Auth All Cases E2E Test
# Comprehensive test for positive and negative authentication/authorization paths.

set -e

# Configuration
API_URL="${API_URL:-http://localhost:4010}"
REDIS_CONTAINER="${REDIS_CONTAINER:-gridtokenx-redis}"
DB_CONTAINER="${DB_CONTAINER:-gridtokenx-postgres}"
DB_USER="${DB_USER:-gridtokenx_user}"
DB_NAME="${DB_NAME:-gridtokenx}"

TIMESTAMP=$(date +%s)
EMAIL="auth_${TIMESTAMP}@grx.test"
USERNAME="user_auth_${TIMESTAMP}"
PASSWORD="GridTokenX-$2024-@Secret"
WRONG_PASSWORD="WrongPassword123!"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo "--------------------------------------------------"
echo "🛡️ Starting Comprehensive Auth E2E Test"
echo "--------------------------------------------------"

# --- SECTION 1: REGISTRATION ---
log_info ">>> SECTION 1: REGISTRATION"

# Case 1.1: Weak Password
log_info "Case 1.1: Register with weak password..."
RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{\"email\":\"weak@test.com\",\"username\":\"weakuser\",\"password\":\"12345\"}")
CODE=$(echo "$RESP" | jq -r '.error.code // empty')
if [[ "$CODE" == "VAL_3001" ]]; then
    log_pass "Correctly rejected weak password (VAL_3001)."
else
    log_fail "Failed to reject weak password. Code: $CODE"
fi

# Case 1.2: Invalid Email
log_info "Case 1.2: Register with invalid email..."
# Note: Current implementation might just fail on regex or basic validation
RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{\"email\":\"not-an-email\",\"username\":\"invalidemail\",\"password\":\"$PASSWORD\"}")
CODE=$(echo "$RESP" | jq -r '.error.code // empty')
if [[ "$CODE" == "VAL_3006" ]]; then
    log_pass "Correctly rejected invalid email (VAL_3006)."
else
    log_fail "Failed to reject invalid email. Code: $CODE"
fi

# Case 1.3: Success Registration
log_info "Case 1.3: Success registration..."
REG_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{\"email\":\"$EMAIL\",\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")
USER_ID=$(echo "$REG_RESP" | jq -r '.id // empty')
if [ -n "$USER_ID" ]; then
    log_pass "Registration successful ($USER_ID)."
else
    log_fail "Registration failed: $REG_RESP"
fi

# Mandatory: Verify email to activate user for login tests
log_info "Verifying account to activate user..."
VERIFY_TOKEN=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT email_verification_token FROM users WHERE id = '$USER_ID';" | tr -d '[:space:]')
curl -s -X GET "$API_URL/api/v1/auth/verify?token=$VERIFY_TOKEN" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" > /dev/null
log_pass "Account Activated."

# Case 1.4: Duplicate Registration
log_info "Case 1.4: Register with existing email..."
RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{\"email\":\"$EMAIL\",\"username\":\"newuser\",\"password\":\"$PASSWORD\"}")
CODE=$(echo "$RESP" | jq -r '.error.code // empty')
if [[ "$CODE" == "RES_4002" ]] || [[ "$CODE" == "RES_4003" ]]; then
    log_pass "Correctly rejected duplicate email ($CODE)."
else
    log_fail "Failed to reject duplicate email. Code: $CODE"
fi

# --- SECTION 2: LOGIN ---
log_info ">>> SECTION 2: LOGIN"

# Case 2.1: Login with wrong password
log_info "Case 2.1: Login with wrong password..."
RESP=$(curl -s -X POST "$API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{\"username\":\"$USERNAME\",\"password\":\"$WRONG_PASSWORD\"}")
CODE=$(echo "$RESP" | jq -r '.error.code // empty')
if [[ "$CODE" == "AUTH_1001" ]]; then
    log_pass "Correctly rejected wrong password (AUTH_1001)."
else
    log_fail "Failed to reject wrong password. Code: $CODE"
fi

# Case 2.2: Login with non-existent user
log_info "Case 2.2: Login with non-existent user..."
RESP=$(curl -s -X POST "$API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{\"username\":\"nonexistent_user\",\"password\":\"$PASSWORD\"}")
CODE=$(echo "$RESP" | jq -r '.error.code // empty')
if [[ "$CODE" == "AUTH_1001" ]] || [[ "$CODE" == "RES_4001" ]]; then
    log_pass "Correctly handled non-existent user ($CODE)."
else
    log_fail "Failed to handle non-existent user. Code: $CODE"
fi

# Case 2.3: Account Lockout
log_info "Case 2.3: Testing account lockout (5 failed attempts)..."
# Clear Redis lockout just in case
docker exec -i "$REDIS_CONTAINER" redis-cli del "iam:account_lock:$USERNAME" > /dev/null
docker exec -i "$REDIS_CONTAINER" redis-cli del "iam:login_attempts:$USERNAME" > /dev/null

for i in {1..5}; do
    curl -s -X POST "$API_URL/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -H "x-gridtokenx-role: api-gateway" \
        -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$WRONG_PASSWORD\"}" > /dev/null
done

RESP=$(curl -s -X POST "$API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")
CODE=$(echo "$RESP" | jq -r '.error.code // empty')
if [[ "$CODE" == "AUTH_1006" ]]; then
    log_pass "Account successfully locked after 5 attempts (AUTH_1006)."
else
    log_fail "Account NOT locked. Code: $CODE. Response: $RESP"
fi

# Unlock for further tests
docker exec -i "$REDIS_CONTAINER" redis-cli del "iam:account_lock:$USERNAME" > /dev/null

# --- SECTION 3: JWT & PROTECTED ROUTES ---
log_info ">>> SECTION 3: JWT & PROTECTED ROUTES"

# Case 3.1: Missing Authorization Header
log_info "Case 3.1: Access /me without JWT..."
RESP=$(curl -s -X GET "$API_URL/api/v1/users/me" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025")
CODE=$(echo "$RESP" | jq -r '.error.code // empty')
if [[ "$CODE" == "AUTH_1004" ]]; then
    log_pass "Correctly rejected missing JWT (AUTH_1004)."
else
    log_fail "Failed to reject missing JWT. Code: $CODE"
fi

# Case 3.2: Invalid JWT
log_info "Case 3.2: Access /me with invalid JWT..."
RESP=$(curl -s -X GET "$API_URL/api/v1/users/me" \
    -H "Authorization: Bearer invalid-token-here" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025")
CODE=$(echo "$RESP" | jq -r '.error.code // empty')
if [[ "$CODE" == "AUTH_1003" ]]; then
    log_pass "Correctly rejected invalid JWT (AUTH_1003)."
else
    log_fail "Failed to reject invalid JWT. Code: $CODE"
fi

# --- SECTION 4: RBAC ---
log_info ">>> SECTION 4: RBAC (Role-Based Access Control)"

# Case 4.1: Missing Service Role Headers
log_info "Case 4.1: Access /me without Service Role headers..."
RESP=$(curl -s -X GET "$API_URL/api/v1/users/me")
# Extracting any error since internal role check returns Unauthorized or Forbidden
if [[ "$(echo "$RESP" | jq -r '.error // empty')" != "" ]]; then
    log_pass "Correctly rejected request without service role headers."
else
    log_fail "Failed to reject request without service role headers. Response: $RESP"
fi

# Case 4.2: Invalid Gateway Secret
log_info "Case 4.2: Access /me with invalid gateway secret..."
RESP=$(curl -s -X GET "$API_URL/api/v1/users/me" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: wrong-secret")
if [[ "$(echo "$RESP" | jq -r '.error // empty')" != "" ]]; then
    log_pass "Correctly rejected invalid gateway secret."
else
    log_fail "Failed to reject invalid gateway secret. Response: $RESP"
fi

echo "--------------------------------------------------"
log_pass "🏆 ALL AUTH CASES VERIFIED"
echo "--------------------------------------------------"
