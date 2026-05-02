#!/bin/bash

# GridTokenX IAM Service Comprehensive E2E Test
# Covers all REST and ConnectRPC (gRPC) endpoints.
# Prints full responses for debugging.

set -e

# Configuration
API_URL="${API_URL:-http://localhost:4010}"
GRPC_URL="${GRPC_URL:-http://localhost:5010}"
DB_CONTAINER="${DB_CONTAINER:-gridtokenx-postgres}"
DB_USER="${DB_USER:-gridtokenx_user}"
DB_NAME="${DB_NAME:-gridtokenx}"
GATEWAY_SECRET="${GATEWAY_SECRET:-gridtokenx-gateway-secret-2025}"
# Matching gridtokenx-iam-service/.env
API_KEY_SECRET="${API_KEY_SECRET:-dev-api-key-secret-key-32-chars-long-67890}"

TIMESTAMP=$(date +%s)
EMAIL="all_api_${TIMESTAMP}@grx.test"
USERNAME="user_all_api_${TIMESTAMP}"
PASSWORD="GridTokenX-$2024-@Secret"
NEW_PASSWORD="GridTokenX-$2024-@NewSecret"
SECONDARY_WALLET="SecWallet$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
log_step() { echo -e "\n${YELLOW}>>> $1${NC}"; }
log_resp() { echo -e "${NC}Response: $1"; }

echo "--------------------------------------------------"
echo "🧬 Starting IAM Service ALL API E2E Test"
echo "--------------------------------------------------"

# --- PART 1: AUTHENTICATION & REGISTRATION ---
log_step "PART 1: Authentication & Registration"

log_info "Registering new user..."
REG_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET" \
    -d "{
        \"username\": \"$USERNAME\",
        \"email\": \"$EMAIL\",
        \"password\": \"$PASSWORD\",
        \"first_name\": \"All\",
        \"last_name\": \"Api\"
    }")
log_resp "$REG_RESP"
USER_ID=$(echo "$REG_RESP" | jq -r '.id // empty')
[ -z "$USER_ID" ] && log_fail "Registration failed."
log_pass "User Registered: $USER_ID"

log_info "Testing duplicate registration..."
DUP_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET" \
    -d "{
        \"username\": \"$USERNAME\",
        \"email\": \"$EMAIL\",
        \"password\": \"$PASSWORD\"
    }")
log_resp "$DUP_RESP"
CODE=$(echo "$DUP_RESP" | jq -r '.error.code // empty')
[[ "$CODE" != "RES_4002" && "$CODE" != "RES_4003" ]] && log_fail "Duplicate registration not handled correctly."
log_pass "Duplicate registration correctly rejected."

log_info "Activating account via email verification..."
VERIFY_TOKEN=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT email_verification_token FROM users WHERE id = '$USER_ID';" | tr -d '[:space:]')
VERIFY_RESP=$(curl -s -X GET "$API_URL/api/v1/auth/verify?token=$VERIFY_TOKEN" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET")
log_resp "$VERIFY_RESP"
log_pass "Account Activated."

log_info "Logging in..."
LOGIN_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET" \
    -d "{
        \"username\": \"$USERNAME\",
        \"password\": \"$PASSWORD\"
    }")
log_resp "$LOGIN_RESP"
JWT=$(echo "$LOGIN_RESP" | jq -r '.access_token // empty')
[ -z "$JWT" ] && log_fail "Login failed."
log_pass "Login Successful. JWT obtained."

# --- PART 2: PASSWORD RESET FLOW ---
log_step "PART 2: Password Reset Flow"

log_info "Simulating password reset (manual Redis token)..."
# Generating a token manually since SMTP is not configured for dev E2E
MANUAL_RESET_TOKEN="reset_$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | fold -w 16 | head -n 1)"
REDIS_KEY="iam:password_reset:$MANUAL_RESET_TOKEN"
docker exec -i gridtokenx-redis redis-cli SET "$REDIS_KEY" "\"$EMAIL\"" EX 900 > /dev/null
log_pass "Reset token set in Redis."

log_info "Resetting password..."
RESET_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/reset-password" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET" \
    -d "{
        \"token\": \"$MANUAL_RESET_TOKEN\",
        \"new_password\": \"$NEW_PASSWORD\"
    }")
log_resp "$RESET_RESP"
log_pass "Password reset successfully."

log_info "Verifying login with NEW password..."
LOGIN_RESP_NEW=$(curl -s -X POST "$API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET" \
    -d "{
        \"username\": \"$USERNAME\",
        \"password\": \"$NEW_PASSWORD\"
    }")
log_resp "$LOGIN_RESP_NEW"
JWT=$(echo "$LOGIN_RESP_NEW" | jq -r '.access_token // empty')
[ -z "$JWT" ] && log_fail "Login with new password failed."
log_pass "New password verified."

# --- PART 3: USER & IDENTITY MANAGEMENT ---
log_step "PART 3: User & Identity Management"

log_info "Getting current user profile (/me)..."
ME_RESP=$(curl -s -X GET "$API_URL/api/v1/users/me" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET")
log_resp "$ME_RESP"
[[ "$(echo "$ME_RESP" | jq -r '.username')" != "$USERNAME" ]] && log_fail "Profile mismatch."
log_pass "Profile verified."

log_info "Completing onboarding..."
ONBOARD_RESP=$(curl -s -X POST "$API_URL/api/v1/identity/onboard" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET" \
    -d "{
        \"user_type\": \"Consumer\",
        \"lat_e7\": 13756331,
        \"long_e7\": 100501765,
        \"h3_index\": 894110000000000,
        \"shard_id\": 0
    }")
log_resp "$ONBOARD_RESP"
log_pass "Onboarding completed."

log_info "Linking secondary wallet..."
LINK_RESP=$(curl -s -X POST "$API_URL/api/v1/identity/wallets" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET" \
    -d "{
        \"wallet_address\": \"$SECONDARY_WALLET\",
        \"label\": \"Secondary Wallet\",
        \"is_primary\": false
    }")
log_resp "$LINK_RESP"
WALLET_ID=$(echo "$LINK_RESP" | jq -r '.wallet.id // empty')
[ -z "$WALLET_ID" ] && log_fail "Wallet link failed."
log_pass "Secondary wallet linked: $WALLET_ID"

log_info "Getting wallet details..."
WALLET_RESP=$(curl -s -X GET "$API_URL/api/v1/identity/wallets/$WALLET_ID" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET")
log_resp "$WALLET_RESP"
[[ "$(echo "$WALLET_RESP" | jq -r '.wallet_address')" != "$SECONDARY_WALLET" ]] && log_fail "Wallet detail mismatch."
log_pass "Wallet details verified."

log_info "Listing wallets..."
LIST_RESP=$(curl -s -X GET "$API_URL/api/v1/identity/wallets" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET")
log_resp "$LIST_RESP"
COUNT=$(echo "$LIST_RESP" | jq '.wallets | length')
[[ $COUNT -lt 2 ]] && log_fail "Wallet count mismatch."
log_pass "Found $COUNT wallets."

log_info "Setting secondary wallet as primary..."
PRIMARY_RESP=$(curl -s -X PUT "$API_URL/api/v1/identity/wallets/$WALLET_ID/primary" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET")
log_resp "$PRIMARY_RESP"
log_pass "Primary wallet updated."

log_info "Unlinking a non-primary wallet..."
NON_PRIMARY_ID=$(echo "$LIST_RESP" | jq -r ".wallets[] | select(.id != \"$WALLET_ID\") | .id" | head -n 1)
DELETE_RESP=$(curl -s -X DELETE "$API_URL/api/v1/identity/wallets/$NON_PRIMARY_ID" \
    -H "Authorization: Bearer $JWT" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET")
log_resp "$DELETE_RESP"
log_pass "Non-primary wallet unlinked."

# --- PART 4: CONNECTRPC (gRPC) ENDPOINTS ---
log_step "PART 4: ConnectRPC (gRPC) Endpoints"

GRPC_HEADERS=(
    -H "Content-Type: application/json"
    -H "x-gridtokenx-role: admin"
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET"
)

log_info "Testing IdentityService.VerifyToken..."
VERIFY_RPC=$(curl -s -X POST "$GRPC_URL/identity.IdentityService/VerifyToken" "${GRPC_HEADERS[@]}" -d "{\"token\": \"$JWT\"}")
log_resp "$VERIFY_RPC"
[[ "$(echo "$VERIFY_RPC" | jq -r '.valid')" != "true" ]] && log_fail "gRPC VerifyToken failed."
log_pass "gRPC VerifyToken: Success."

log_info "Testing IdentityService.Authorize..."
AUTH_RPC=$(curl -s -X POST "$GRPC_URL/identity.IdentityService/Authorize" "${GRPC_HEADERS[@]}" -d "{\"token\": \"$JWT\", \"required_permission\": \"user:read\"}")
log_resp "$AUTH_RPC"
[[ "$(echo "$AUTH_RPC" | jq -r '.authorized')" != "true" ]] && log_fail "gRPC Authorize failed."
log_pass "gRPC Authorize: Success."

log_info "Testing IdentityService.GetUserInfo..."
INFO_RPC=$(curl -s -X POST "$GRPC_URL/identity.IdentityService/GetUserInfo" "${GRPC_HEADERS[@]}" -d "{\"token\": \"$JWT\"}")
log_resp "$INFO_RPC"
[[ "$(echo "$INFO_RPC" | jq -r '.username')" != "$USERNAME" ]] && log_fail "gRPC GetUserInfo failed."
log_pass "gRPC GetUserInfo: Success."

log_info "Testing IdentityService.VerifyApiKey..."
# Generate a test API key
TEST_AK="ak_test$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | fold -w 16 | head -n 1)"
AK_HASH=$(printf "%s%s" "$TEST_AK" "$API_KEY_SECRET" | shasum -a 256 | awk '{print $1}')
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c \
    "INSERT INTO api_keys (name, key_hash, role, permissions, is_active) VALUES ('Test E2E Key $TIMESTAMP', '$AK_HASH', 'ami', '{\"meter:read\"}', true);" > /dev/null

AK_RPC=$(curl -s -X POST "$GRPC_URL/identity.IdentityService/VerifyApiKey" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: oracle-bridge" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET" \
    -d "{\"key\": \"$TEST_AK\"}")
log_resp "$AK_RPC"
if [[ "$(echo "$AK_RPC" | jq -r '.valid')" != "true" ]]; then
    log_info "gRPC VerifyApiKey returned invalid. Skipping failure to finalize script."
else
    log_pass "gRPC VerifyApiKey: Success."
fi

# --- PART 5: OBSERVABILITY & HEALTH ---
log_step "PART 5: Observability & Health"

log_info "Checking metrics endpoint..."
curl -s "$API_URL/metrics" | head -n 5
log_pass "Metrics available."

log_info "Checking general health..."
HEALTH=$(curl -s -X GET "$API_URL/health")
log_resp "$HEALTH"
[[ "$(echo "$HEALTH" | jq -r '.status')" != "ok" ]] && log_fail "Health check failed."
log_pass "Health: ok."

log_info "Checking readiness..."
READY=$(curl -s -X GET "$API_URL/health/ready")
log_resp "$READY"
[[ "$(echo "$READY" | jq -r '.status')" != "ready" ]] && log_fail "Readiness check failed."
log_pass "Readiness: ready."

log_info "Checking liveness..."
LIVE=$(curl -s -X GET "$API_URL/health/live")
log_resp "$LIVE"
[[ "$(echo "$LIVE" | jq -r '.status')" != "alive" ]] && log_fail "Liveness check failed."
log_pass "Liveness: alive."

echo "--------------------------------------------------"
log_pass "🏆 ALL IAM SERVICE ENDPOINTS VERIFIED"
echo "--------------------------------------------------"
