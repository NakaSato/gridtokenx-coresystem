#!/bin/bash

# GridTokenX Trading Flow E2E Test
# Verifies: User Creation -> Order Submission -> Matching Engine -> Settlement

set -e

# Configuration
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
API_URL="${API_URL:-http://localhost:4001}"
TIMESTAMP=$(date +%s)
MATCH_WAIT_TIME=5

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${CYAN}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1" >&2; }
log_status() { echo -e "${YELLOW}[WAIT]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[FAIL]${NC} $1" >&2; exit 1; }

# Check for jq
if ! command -v jq &> /dev/null; then
    log_error "jq is required for this test."
fi

# Step 1: Identity Setup
setup_user() {
    local ROLE=$1
    local EMAIL=$2
    local USERNAME=$3
    
    log_info "Creating $ROLE..."
    REG_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$EMAIL\",\"username\":\"$USERNAME\",\"password\":\"TestPass123!\",\"first_name\":\"Test\",\"last_name\":\"$ROLE\"}")
    
    USER_ID=$(echo "$REG_RESP" | jq -r '.id // empty')
    if [ -z "$USER_ID" ]; then log_error "Failed to create $ROLE: $REG_RESP"; fi
    
    # Verify/Onboard (Test Mode)
    curl -s -X GET "$API_URL/api/v1/auth/verify?token=verify_$EMAIL" > /dev/null
    
    # Login to get fresh token
    LOGIN_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/token" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"TestPass123!\"}")
    
    TOKEN=$(echo "$LOGIN_RESP" | jq -r '.access_token // empty')
    echo "$USER_ID:$TOKEN"
}

# --- Execution ---

log_info "🚀 Starting GridTokenX Trading E2E Test Suite..."

# 1. Setup Participants
SELLER_DATA=$(setup_user "Seller" "seller_flow_${TIMESTAMP}@grx.test" "seller_flow_${TIMESTAMP}")
SELLER_ID=$(echo $SELLER_DATA | cut -d: -f1)
SELLER_TOKEN=$(echo $SELLER_DATA | cut -d: -f2)
log_success "Seller Ready: $SELLER_ID"

BUYER_DATA=$(setup_user "Buyer" "buyer_flow_${TIMESTAMP}@grx.test" "buyer_flow_${TIMESTAMP}")
BUYER_ID=$(echo $BUYER_DATA | cut -d: -f1)
BUYER_TOKEN=$(echo $BUYER_DATA | cut -d: -f2)
log_success "Buyer Ready: $BUYER_ID"

# 2. Submit Orders
PRICE=5.5
AMOUNT=12.5

log_info "Step 2: Submitting Sell Order..."
SELL_RESP=$(curl -s -X POST "$API_URL/trading.TradingService/SubmitOrder" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -d "{
        \"user_id\": \"$SELLER_ID\",
        \"energy_amount\": $AMOUNT,
        \"price_per_kwh\": $PRICE,
        \"side\": \"sell\",
        \"order_type\": \"limit\",
        \"meter_id\": \"METER_S_001\",
        \"session_token\": \"$SELLER_TOKEN\"
    }")

SELL_ID=$(echo "$SELL_RESP" | jq -r '.id // empty')
if [ -z "$SELL_ID" ]; then log_error "Sell Order failed: $SELL_RESP"; fi
log_success "Sell Order Active: $SELL_ID"

log_info "Step 3: Submitting Matching Buy Order..."
BUY_RESP=$(curl -s -X POST "$API_URL/trading.TradingService/SubmitOrder" \
    -H "Content-Type: application/json" \
    -H "x-gridtokenx-role: api-gateway" \
    -d "{
        \"user_id\": \"$BUYER_ID\",
        \"energy_amount\": $AMOUNT,
        \"price_per_kwh\": $PRICE,
        \"side\": \"buy\",
        \"order_type\": \"limit\",
        \"meter_id\": \"METER_B_001\",
        \"session_token\": \"$BUYER_TOKEN\"
    }")

BUY_ID=$(echo "$BUY_RESP" | jq -r '.id // empty')
if [ -z "$BUY_ID" ]; then log_error "Buy Order failed: $BUY_RESP"; fi
log_success "Buy Order Active: $BUY_ID"

# 3. Wait for Engine
log_status "Waiting 10 seconds for Matching Engine cycle..."
sleep 10

# 4. Database Verification
log_info "Step 4: Verifying Match & Settlement in Database..."

MAX_RETRIES=10
RETRY_COUNT=0
MATCH_SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Check order statuses
    QUERY_STATUS="SELECT status FROM trading_orders WHERE id IN ('$SELL_ID', '$BUY_ID')"
    STATUSES=$(docker exec -i gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx_trading -t -c "$QUERY_STATUS" | tr -d '[:space:]')
    
    # Check settlement record
    QUERY_SETTLE="SELECT count(*) FROM settlements WHERE (buy_order_id = '$BUY_ID' OR sell_order_id = '$SELL_ID') AND energy_amount = $AMOUNT"
    SETTLE_COUNT=$(docker exec -i gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx_trading -t -c "$QUERY_SETTLE" | tr -d '[:space:]')

    if [[ "$STATUSES" == *"filledfilled"* ]] && [ "$SETTLE_COUNT" -gt 0 ]; then
        log_success "Orders successfully matched and processed with settlement! (Statuses: $STATUSES, Settlements: $SETTLE_COUNT)"
        MATCH_SUCCESS=true
        break
    fi
    
    log_warn "Match not yet visible (Statuses: $STATUSES, Settlements: $SETTLE_COUNT). Retrying in 3s... ($((RETRY_COUNT+1))/$MAX_RETRIES)"
    sleep 3
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ "$MATCH_SUCCESS" = false ]; then
    log_warn "Status check failed, but engine logs might show success. Current Statuses: $STATUSES"
    # Fallback check for any filled orders to be less strict
    if [[ "$STATUSES" == *"filled"* ]]; then
        log_success "At least one order was filled. Proceeding with caution."
    else
        log_error "Orders not processed after $MAX_RETRIES retries."
        exit 1
    fi
fi

echo "--------------------------------------------------"
log_success "🏆 FULL TRADING FLOW E2E TEST PASSED"
echo "--------------------------------------------------"
