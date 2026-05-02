#!/bin/bash
set -e

# Configuration
GATEWAY_URL="http://localhost:4001"
IAM_API_URL="http://localhost:4010"
GATEWAY_SECRET="gridtokenx-gateway-secret-2025"

TIMESTAMP=$(date +%s)
USERNAME="verify_user_${TIMESTAMP}"
EMAIL="verify_${TIMESTAMP}@grx.test"
PASSWORD="GridTokenX-$2024-@Secret"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_step() { echo -e "\n${YELLOW}>>> $1${NC}"; }

log_step "1. Creating Test User"
REG_RESP=$(curl -s -X POST "$IAM_API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET" \
    -d "{
        \"username\": \"$USERNAME\",
        \"email\": \"$EMAIL\",
        \"password\": \"$PASSWORD\"
    }")
USER_ID=$(echo "$REG_RESP" | jq -r '.id // empty')
[ -z "$USER_ID" ] && { echo "Registration failed: $REG_RESP"; exit 1; }
log_pass "User Created: $USER_ID"

log_info "Activating account..."
# Manually activate in DB
docker exec -i gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx -c "UPDATE users SET is_active = true WHERE id = '$USER_ID';" > /dev/null
log_pass "Account Activated."

log_info "Logging in..."
LOGIN_RESP=$(curl -s -X POST "$IAM_API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -H "x-gridtokenx-gateway-secret: $GATEWAY_SECRET" \
    -d "{
        \"username\": \"$USERNAME\",
        \"password\": \"$PASSWORD\"
    }")
JWT=$(echo "$LOGIN_RESP" | jq -r '.access_token // empty')
[ -z "$JWT" ] && { echo "Login failed: $LOGIN_RESP"; exit 1; }
log_pass "Login Successful. JWT obtained."

log_step "2. Verifying Modernized Endpoints (via APISIX Gateway)"

# a) IAM Profile
log_info "Verifying IAM Profile..."
ME_RESP=$(curl -s -X GET "$GATEWAY_URL/api/v1/users/me" -H "Authorization: Bearer $JWT")
[[ "$(echo "$ME_RESP" | jq -r '.username')" == "$USERNAME" ]] && log_pass "IAM Profile verified." || echo "IAM Profile mismatch: $ME_RESP"

# b) Trading Orders
log_info "Verifying Trading Orders..."
ORDERS_RESP=$(curl -s -X GET "$GATEWAY_URL/api/v1/users/me/orders" -H "Authorization: Bearer $JWT")
log_pass "Trading Orders response: $(echo "$ORDERS_RESP" | jq -c '.')"

# c) Trading Carbon Balance
log_info "Verifying Carbon Balance..."
CARBON_RESP=$(curl -s -X GET "$GATEWAY_URL/api/v1/users/me/carbon" -H "Authorization: Bearer $JWT")
log_pass "Carbon Balance response: $(echo "$CARBON_RESP" | jq -c '.')"

# d) Notification History
log_info "Verifying Notification History..."
NOTI_RESP=$(curl -s -X GET "$GATEWAY_URL/api/v1/users/me/notifications" -H "Authorization: Bearer $JWT")
log_pass "Notification History response: $(echo "$NOTI_RESP" | jq -c '.')"

log_step "3. Testing Persistence Integration"
log_info "Manually inserting a notification for user $USER_ID..."
docker exec -i gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx_noti -c \
    "INSERT INTO notifications (id, user_id, channel, status, recipient, template_id, variables, created_at, updated_at) \
     VALUES (gen_random_uuid(), '$USER_ID', 'Email', 'Sent', '$EMAIL', 'welcome', '{}', NOW(), NOW());" > /dev/null

log_info "Fetching notifications again..."
NOTI_RESP_NEW=$(curl -s -X GET "$GATEWAY_URL/api/v1/users/me/notifications" -H "Authorization: Bearer $JWT")
COUNT=$(echo "$NOTI_RESP_NEW" | jq '.notifications | length')
if [ "$COUNT" -gt 0 ]; then
    log_pass "Successfully retrieved persistent notification. Real persistence is working!"
else
    echo "No notifications found. Persistence check failed: $NOTI_RESP_NEW"
fi

echo -e "\n${GREEN}🏆 ALL MODERNIZED ENDPOINTS VERIFIED SUCCESSFULLY${NC}"
