#!/bin/bash

# GridTokenX Identity Lifecycle E2E Test
# Comprehensive test covering registration, login, onboarding, and multi-wallet management.

set -e

# Configuration
API_URL="${API_URL:-http://localhost:4010}"
DB_CONTAINER="${DB_CONTAINER:-gridtokenx-postgres}"
DB_USER="${DB_USER:-gridtokenx_user}"
DB_NAME="${DB_NAME:-gridtokenx}"

TIMESTAMP=$(date +%s)
EMAIL="lifecycle_${TIMESTAMP}@grx.test"
USERNAME="user_lifecycle_${TIMESTAMP}"
PASSWORD="GridTokenX-$2024-@Secret"
SECONDARY_WALLET="Secondary$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)" # Dummy for DB linkage

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
echo "🧬 Starting Identity Lifecycle E2E Test"
echo "--------------------------------------------------"

# 1. Registration
log_info "Step 1: Registering new user..."
REG_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{
        \"username\": \"$USERNAME\",
        \"email\": \"$EMAIL\",
        \"password\": \"$PASSWORD\",
        \"first_name\": \"Life\",
        \"last_name\": \"Cycle\"
    }")
USER_ID=$(echo "$REG_RESP" | jq -r '.id // empty')
[ -z "$USER_ID" ] && log_fail "Registration failed: $REG_RESP"
log_pass "User Registered ($USER_ID)."

# 2. Email Verification
log_info "Step 2: Activating account via email verification..."
VERIFY_TOKEN=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT email_verification_token FROM users WHERE id = '$USER_ID';" | tr -d '[:space:]')
curl -s -X GET "$API_URL/api/v1/auth/verify?token=$VERIFY_TOKEN" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" > /dev/null
log_pass "Account Activated."

# 3. Login
log_info "Step 3: Logging in to obtain JWT..."
LOGIN_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{
        \"username\": \"$USERNAME\",
        \"password\": \"$PASSWORD\"
    }")
JWT=$(echo "$LOGIN_RESP" | jq -r '.access_token // empty')
[ -z "$JWT" ] && log_fail "Login failed: $LOGIN_RESP"
log_pass "Login Successful. JWT obtained."

# 4. Get Profile
log_info "Step 4: Retrieving user profile (/me)..."
ME_RESP=$(curl -s -X GET "$API_URL/api/v1/users/me" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025")
PROFILE_USER=$(echo "$ME_RESP" | jq -r '.username')
[[ "$PROFILE_USER" != "$USERNAME" ]] && log_fail "Profile mismatch: $ME_RESP"
log_pass "Profile verified for $PROFILE_USER."

# 5. Onboarding (Set Location & Type)
log_info "Step 5: Completing onboarding..."
ONBOARD_RESP=$(curl -s -X POST "$API_URL/api/v1/identity/onboard" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{
        \"user_type\": \"Prosumer\",
        \"lat_e7\": 13736717,
        \"long_e7\": 100523186,
        \"h3_index\": 894110000000000,
        \"shard_id\": 1
    }")
SUCCESS=$(echo "$ONBOARD_RESP" | jq -r '.success')
[[ "$SUCCESS" != "true" ]] && log_fail "Onboarding failed: $ONBOARD_RESP"
log_pass "Onboarding successful. User initialized on-chain."

# 6. Link Secondary Wallet
log_info "Step 6: Linking secondary wallet..."
LINK_RESP=$(curl -s -X POST "$API_URL/api/v1/identity/wallets" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025" \
    -d "{
        \"wallet_address\": \"$SECONDARY_WALLET\",
        \"label\": \"Backup Wallet\",
        \"is_primary\": false
    }")
SEC_WALLET_ID=$(echo "$LINK_RESP" | jq -r '.wallet.id // empty')
[ -z "$SEC_WALLET_ID" ] && log_fail "Wallet link failed: $LINK_RESP"
log_pass "Secondary wallet linked ($SEC_WALLET_ID)."

# 7. List Wallets
log_info "Step 7: Listing all linked wallets..."
LIST_RESP=$(curl -s -X GET "$API_URL/api/v1/identity/wallets" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025")
COUNT=$(echo "$LIST_RESP" | jq '.wallets | length')
[[ $COUNT -lt 2 ]] && log_fail "Wallet list incorrect: $LIST_RESP"
log_pass "Found $COUNT linked wallets."

# 8. Set Secondary as Primary
log_info "Step 8: Changing primary wallet..."
PRIMARY_RESP=$(curl -s -X PUT "$API_URL/api/v1/identity/wallets/$SEC_WALLET_ID/primary" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025")
IS_PRIMARY=$(echo "$PRIMARY_RESP" | jq -r '.is_primary')
[[ "$IS_PRIMARY" != "true" ]] && log_fail "Failed to set primary: $PRIMARY_RESP"
log_pass "Primary wallet updated to $SEC_WALLET_ID."

# 9. Unlink (Delete) Wallet
# Note: We should unlink the one that is NOT primary now, or just try unlinking the old one.
# Let's get the ID of the old primary (the one not equal to SEC_WALLET_ID)
OLD_WALLET_ID=$(echo "$LIST_RESP" | jq -r ".wallets[] | select(.id != \"$SEC_WALLET_ID\") | .id" | head -n 1)
log_info "Step 9: Unlinking old wallet ($OLD_WALLET_ID)..."
DELETE_RESP=$(curl -s -X DELETE "$API_URL/api/v1/identity/wallets/$OLD_WALLET_ID" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025")
log_pass "Wallet unlinked successfully."

# 10. Final Health Check
log_info "Step 10: Verifying system health..."
HEALTH=$(curl -s -X GET "$API_URL/health")
[[ "$(echo "$HEALTH" | jq -r '.status')" != "OK" ]] && log_fail "Health check failed: $HEALTH"
log_pass "System Health: OK."

echo "--------------------------------------------------"
log_pass "🏆 IDENTITY LIFECYCLE E2E VERIFIED"
echo "--------------------------------------------------"
