#!/bin/bash

# GridTokenX IAM Full Registration E2E Test
# Verifies: User Creation -> Email Verification -> Wallet Generation

set -e

# Configuration
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
API_URL="${API_URL:-http://localhost:4001}"
TIMESTAMP=$(date +%s)

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# Check for jq
if ! command -v jq &> /dev/null; then
    log_error "jq is required for this test."
fi

test_registration_flow() {
    local ROLE_NAME=$1
    local EMAIL=$2
    local USERNAME=$3
    local PASSWORD="GridTokenX!2025!Security"

    echo "--------------------------------------------------"
    echo "🚀 Testing Registration Flow for: $ROLE_NAME"
    echo "--------------------------------------------------"

    # 1. Register User
    log_info "Step 1: Registering $ROLE_NAME ($EMAIL)..."
    REG_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
        -H "Content-Type: application/json" \
        -H "x-gridtokenx-role: api-gateway" \
        -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
        -d "{
            \"email\": \"$EMAIL\",
            \"username\": \"$USERNAME\",
            \"password\": \"$PASSWORD\",
            \"first_name\": \"Test\",
            \"last_name\": \"$ROLE_NAME\"
        }")

    SUCCESS=$(echo "$REG_RESP" | jq -r '.message // empty')
    if [[ "$SUCCESS" != *"registered successfully"* ]]; then
        log_error "Registration failed for $ROLE_NAME. Response: $REG_RESP"
    fi
    log_success "Account Created."

    # 2. Verify Account (Test Mode)
    log_info "Step 2: Verifying Account via test token..."
    VERIFY_RESP=$(curl -s -X GET "$API_URL/api/v1/auth/verify?token=verify_$EMAIL" \
        -H "x-gridtokenx-role: api-gateway" \
        -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025")
    
    IS_VERIFIED=$(echo "$VERIFY_RESP" | jq -r '.success // false')
    if [ "$IS_VERIFIED" != "true" ]; then
        log_error "Verification failed for $ROLE_NAME. Response: $VERIFY_RESP"
    fi
    
    WALLET_ADDR=$(echo "$VERIFY_RESP" | jq -r '.wallet_address // empty')
    if [ -z "$WALLET_ADDR" ] || [ "$WALLET_ADDR" == "null" ]; then
        log_error "Wallet generation failed during verification for $ROLE_NAME."
    fi
    log_success "Account Verified. Wallet Generated: $WALLET_ADDR"

    # 3. Verify Wallet Persistence & Login
    log_info "Step 3: Verifying Wallet Persistence via /me endpoint..."
    TOKEN=$(echo "$VERIFY_RESP" | jq -r '.auth.access_token // empty')
    
    ME_RESP=$(curl -s -X GET "$API_URL/api/v1/users/me" \
        -H "Authorization: Bearer $TOKEN" \
        -H "x-gridtokenx-role: api-gateway" \
        -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025")
    
    PERSISTED_WALLET=$(echo "$ME_RESP" | jq -r '.wallet_address // empty')
    if [ "$PERSISTED_WALLET" != "$WALLET_ADDR" ]; then
        log_error "Wallet mismatch or missing in user profile. Expected $WALLET_ADDR, got $PERSISTED_WALLET"
    fi
    
    log_success "Wallet Persistence Verified for $ROLE_NAME."
    echo ""
}

# --- Execution ---

log_info "Starting GridTokenX IAM E2E Test Suite..."
echo ""

# Test Seller Flow
test_registration_flow "Seller" "seller_${TIMESTAMP}@grx.test" "seller_${TIMESTAMP}"

# Test Buyer Flow
test_registration_flow "Buyer" "buyer_${TIMESTAMP}@grx.test" "buyer_${TIMESTAMP}"

echo "=================================================="
echo -e "${GREEN}🏆 ALL IAM E2E TESTS PASSED SUCCESSFULLY${NC}"
echo "=================================================="
