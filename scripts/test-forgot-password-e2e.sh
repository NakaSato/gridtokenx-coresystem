#!/bin/bash

# GridTokenX Forgot Password E2E Test
# Verifies: Register -> Verify -> Forgot Password -> Redis Token Retrieval -> Reset Password -> Login with New Password

set -e

# Configuration
API_URL="${API_URL:-http://localhost:4010}"
DB_CONTAINER="${DB_CONTAINER:-gridtokenx-postgres}"
DB_USER="${DB_USER:-gridtokenx_user}"
DB_NAME="${DB_NAME:-gridtokenx}"
REDIS_CONTAINER="${REDIS_CONTAINER:-gridtokenx-redis}"

TIMESTAMP=$(date +%s)
EMAIL="forgot_${TIMESTAMP}@grx.test"
USERNAME="user_forgot_${TIMESTAMP}"
OLD_PASSWORD="GridTokenX-$2024-@OldSecret"
NEW_PASSWORD="GridTokenX-$2025-@NewSecure"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo "--------------------------------------------------"
echo "🚀 Starting Forgot Password E2E Flow"
echo "Target Email: $EMAIL"
echo "--------------------------------------------------"

# 1. Register User
log_info "Step 1: Registering new user..."
REG_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{
        \"email\": \"$EMAIL\",
        \"username\": \"$USERNAME\",
        \"password\": \"$OLD_PASSWORD\",
        \"first_name\": \"Forgot\",
        \"last_name\": \"Tester\"
    }")

USER_ID=$(echo "$REG_RESP" | jq -r '.id')
if [ "$USER_ID" == "null" ]; then
    log_error "Registration failed. Response: $REG_RESP"
fi
log_success "Account Created ($USER_ID)."

# 2. Verify Account (so it's active)
log_info "Step 2: Verifying account..."
VERIFY_TOKEN=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT email_verification_token FROM users WHERE id = '$USER_ID';" | tr -d '[:space:]')
curl -s -X GET "$API_URL/api/v1/auth/verify?token=$VERIFY_TOKEN" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" > /dev/null
log_success "Account Verified."

# 3. Request Password Reset
log_info "Step 3: Requesting password reset..."
FORGOT_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/forgot-password" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{\"email\": \"$EMAIL\"}")

if [[ "$(echo "$FORGOT_RESP" | jq -r '.message')" != *"reset link has been sent"* ]]; then
    log_error "Forgot password request failed. Response: $FORGOT_RESP"
fi
log_success "Reset request successful."

# 4. Retrieve Reset Token from Redis
log_info "Step 4: Retrieving reset token from Redis..."
# We wait a moment for async processing if any (though cache set is sync in AuthService)
sleep 1
REDIS_KEY=$(docker exec -i "$REDIS_CONTAINER" redis-cli keys "iam:password_reset:*" | head -n 1)

if [ -z "$REDIS_KEY" ]; then
    log_error "Failed to find reset token in Redis."
fi

# Key format: iam:password_reset:TOKEN
RESET_TOKEN=${REDIS_KEY#iam:password_reset:}
log_info "Retrieved Token: ${RESET_TOKEN:0:8}..."

# 5. Reset Password
log_info "Step 5: Resetting password with new token..."
RESET_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/reset-password" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{
        \"token\": \"$RESET_TOKEN\",
        \"new_password\": \"$NEW_PASSWORD\"
    }")

if [[ "$(echo "$RESET_RESP" | jq -r '.message')" != *"successfully"* ]]; then
    log_error "Password reset failed. Response: $RESET_RESP"
fi
log_success "Password Reset Successful."

# 6. Verify Old Password Fails
log_info "Step 6: Verifying old password now fails..."
LOGIN_OLD=$(curl -s -X POST "$API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{
        \"username\": \"$USERNAME\",
        \"password\": \"$OLD_PASSWORD\"
    }")

# If it failed, there should be an error code
ERROR_CODE=$(echo "$LOGIN_OLD" | jq -r '.error.code // empty')
if [ -z "$ERROR_CODE" ]; then
    log_error "Old password still works! Response: $LOGIN_OLD"
fi
log_success "Old password correctly rejected (Code: $ERROR_CODE)."

# 7. Verify New Password Works
log_info "Step 7: Verifying new password works..."
LOGIN_NEW=$(curl -s -X POST "$API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{
        \"username\": \"$USERNAME\",
        \"password\": \"$NEW_PASSWORD\"
    }")

JWT=$(echo "$LOGIN_NEW" | jq -r '.access_token // empty')
if [ -z "$JWT" ] || [ "$JWT" == "null" ]; then
    log_error "Login with new password failed. Response: $LOGIN_NEW"
fi
log_success "Login with new password successful."

echo "--------------------------------------------------"
log_success "🏆 FORGOT PASSWORD E2E VERIFIED"
echo "--------------------------------------------------"
