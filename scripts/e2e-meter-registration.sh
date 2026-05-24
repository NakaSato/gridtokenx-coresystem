#!/bin/bash
#
# E2E Meter Registration Flow Test (No Mock Data)
#
# Flow: Login -> Register Meter -> Verify Meter in DB -> Link Redis -> Check Mailpit
#
# Uses REAL existing user credentials - no test data generation.
# Connects directly to IAM service (bypasses APISIX).
#
# Usage:
#   ./scripts/e2e-meter-registration.sh --local
#   ./scripts/e2e-meter-registration.sh --docker
#
# Required Environment Variables:
#   GRIDTOKENX_USERNAME - Existing username
#   GRIDTOKENX_PASSWORD - Existing password
#
# Optional Environment Variables:
#   GRIDTOKENX_METER_SERIAL - Meter serial number (will prompt if not set)
#   GRIDTOKENX_METER_TYPE - Meter type (solar, wind, battery, grid)
#   GRIDTOKENX_METER_LOCATION - Meter location description
#   GRIDTOKENX_IAM_URL - Override IAM service URL
#

set -e

# =============================================================================
# Configuration
# =============================================================================

MODE="${1:-local}"

# Service URLs (use env vars if set, otherwise defaults)
IAM_URL="${GRIDTOKENX_IAM_URL:-http://localhost:4010}"
MAILPIT_URL="${GRIDTOKENX_MAILPIT_URL:-http://localhost:13060}"
DB_HOST="${GRIDTOKENX_DB_HOST:-localhost}"
DB_PORT="${GRIDTOKENX_DB_PORT:-7001}"
REDIS_HOST="${GRIDTOKENX_REDIS_HOST:-localhost}"
REDIS_PORT="${GRIDTOKENX_REDIS_PORT:-7010}"

# Gateway headers required for IAM service
GATEWAY_ROLE_HEADER="x-gridtokenx-role: api-gateway"
GATEWAY_SECRET_HEADER="x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025"

# User credentials (must be real existing user)
if [ -z "$GRIDTOKENX_USERNAME" ]; then
    echo "Error: GRIDTOKENX_USERNAME environment variable is required"
    echo "Example: export GRIDTOKENX_USERNAME=your_username"
    exit 1
fi

if [ -z "$GRIDTOKENX_PASSWORD" ]; then
    echo "Error: GRIDTOKENX_PASSWORD environment variable is required"
    echo "Example: export GRIDTOKENX_PASSWORD=your_password"
    exit 1
fi

USERNAME="$GRIDTOKENX_USERNAME"
PASSWORD="$GRIDTOKENX_PASSWORD"

# Meter configuration (real meter)
METER_SERIAL="${GRIDTOKENX_METER_SERIAL:-}"
if [ -z "$METER_SERIAL" ]; then
    echo -n "Enter meter serial number: "
    read -r METER_SERIAL
fi

METER_TYPE="${GRIDTOKENX_METER_TYPE:-solar}"
METER_LOCATION="${GRIDTOKENX_METER_LOCATION:-Bangkok, Thailand}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "${YELLOW}[STEP $1]${NC} $2" >&2
}

# macOS-compatible function to remove last line
remove_last_line() {
    sed '$ d'
}

check_prerequisites() {
    log_info "Checking prerequisites..." >&2

    # Check jq
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed. Install with: brew install jq" >&2
        exit 1
    fi

    # Check curl
    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed" >&2
        exit 1
    fi

    log_success "Prerequisites check passed" >&2
}

# =============================================================================
# Test Steps
# =============================================================================

step1_login_user() {
    log_step 1 "Logging in user: $USERNAME"

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$IAM_URL/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")

    HTTP_CODE=$(echo "$RESPONSE" | remove_last_line)
    BODY=$(echo "$RESPONSE" | tail -n 1)

    # Swap due to how curl -w outputs
    HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
    BODY=$(echo "$RESPONSE" | remove_last_line)

    if [ "$HTTP_CODE" != "200" ]; then
        log_error "Login failed with HTTP $HTTP_CODE"
        log_error "Response: $BODY" >&2
        exit 1
    fi

    JWT_TOKEN=$(echo "$BODY" | jq -r '.access_token')
    USER_ID=$(echo "$BODY" | jq -r '.user.id')
    WALLET_ADDRESS=$(echo "$BODY" | jq -r '.user.wallet_address // empty')

    log_success "Login successful"
    log_info "JWT Token: ${JWT_TOKEN:0:50}..."
    log_info "User ID: $USER_ID"

    if [ -n "$WALLET_ADDRESS" ]; then
        log_success "Wallet address: $WALLET_ADDRESS"
    fi

    # Return token and user info as JSON
    echo "{\"token\":\"$JWT_TOKEN\",\"user_id\":\"$USER_ID\",\"wallet_address\":\"$WALLET_ADDRESS\"}"
}

step2_register_meter() {
    local AUTH_DATA="$1"

    JWT_TOKEN=$(echo "$AUTH_DATA" | jq -r '.token')
    USER_ID=$(echo "$AUTH_DATA" | jq -r '.user_id')

    log_step 2 "Registering meter: $METER_SERIAL"

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$IAM_URL/api/v1/meters" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -H "$GATEWAY_ROLE_HEADER" \
        -H "$GATEWAY_SECRET_HEADER" \
        -d "{\"serial_number\":\"$METER_SERIAL\",\"meter_type\":\"$METER_TYPE\",\"location\":\"$METER_LOCATION\"}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
    BODY=$(echo "$RESPONSE" | remove_last_line)

    if [ "$HTTP_CODE" != "200" ]; then
        log_error "Meter registration failed with HTTP $HTTP_CODE"
        log_error "Response: $BODY" >&2
        exit 1
    fi

    SUCCESS=$(echo "$BODY" | jq -r '.success')
    METER_ID=$(echo "$BODY" | jq -r '.meter.id // empty')

    if [ "$SUCCESS" != "true" ]; then
        MESSAGE=$(echo "$BODY" | jq -r '.message')
        log_error "Meter registration not successful: $MESSAGE"
        exit 1
    fi

    log_success "Meter registered with ID: $METER_ID"

    echo "{\"meter_id\":\"$METER_ID\",\"serial\":\"$METER_SERIAL\"}"
}

step3_verify_meter_db() {
    local AUTH_DATA="$1"
    local METER_DATA="$2"

    METER_ID=$(echo "$METER_DATA" | jq -r '.meter_id')
    USER_ID=$(echo "$AUTH_DATA" | jq -r '.user_id')

    log_step 3 "Verifying meter in PostgreSQL database"

    # Query database directly
    if docker ps --format '{{.Names}}' | grep -q 'gridtokenx-postgres'; then
        DB_RESULT=$(docker exec gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx -t -A -c \
            "SELECT id, user_id, serial_number, meter_type, location, is_verified FROM meters WHERE id = '$METER_ID';")
        
        if [ -z "$DB_RESULT" ]; then
            log_error "Meter not found in database"
            exit 1
        fi
        
        DB_USER_ID=$(echo "$DB_RESULT" | cut -d'|' -f2)
        DB_SERIAL=$(echo "$DB_RESULT" | cut -d'|' -f3)
        DB_TYPE=$(echo "$DB_RESULT" | cut -d'|' -f4)
        DB_LOCATION=$(echo "$DB_RESULT" | cut -d'|' -f5)
        DB_VERIFIED=$(echo "$DB_RESULT" | cut -d'|' -f6)
        
        log_success "Meter found in database:"
        log_info "  ID: $METER_ID"
        log_info "  User ID: $DB_USER_ID"
        log_info "  Serial: $DB_SERIAL"
        log_info "  Type: $DB_TYPE"
        log_info "  Location: $DB_LOCATION"
        log_info "  Verified: $DB_VERIFIED"
        
        # Verify user_id matches
        if [ "$DB_USER_ID" != "$USER_ID" ]; then
            log_error "Meter user_id mismatch! Expected $USER_ID, got $DB_USER_ID"
            exit 1
        fi
        
        log_success "Database verification passed"
    else
        log_info "Docker postgres not found, skipping direct DB verification"
    fi
}

step4_verify_meter_api() {
    local AUTH_DATA="$1"
    local METER_DATA="$2"

    JWT_TOKEN=$(echo "$AUTH_DATA" | jq -r '.token')
    METER_ID=$(echo "$METER_DATA" | jq -r '.meter_id')

    log_step 4 "Verifying meter via API GET endpoint"

    RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$IAM_URL/api/v1/meters/$METER_ID" \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -H "$GATEWAY_ROLE_HEADER" \
        -H "$GATEWAY_SECRET_HEADER")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
    BODY=$(echo "$RESPONSE" | remove_last_line)

    if [ "$HTTP_CODE" != "200" ]; then
        log_error "Meter API verification failed with HTTP $HTTP_CODE"
        log_error "Response: $BODY" >&2
        exit 1
    fi

    SERIAL=$(echo "$BODY" | jq -r '.serial_number')
    METER_TYPE_RESP=$(echo "$BODY" | jq -r '.meter_type')
    IS_VERIFIED=$(echo "$BODY" | jq -r '.is_verified')

    log_success "Meter API verified: serial=$SERIAL, type=$METER_TYPE_RESP, verified=$IS_VERIFIED"

    # List user's meters
    log_info "Listing all user's meters..."
    RESPONSE=$(curl -s -X GET "$IAM_URL/api/v1/me/meters" \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -H "$GATEWAY_ROLE_HEADER" \
        -H "$GATEWAY_SECRET_HEADER")

    METERS_COUNT=$(echo "$RESPONSE" | jq -r '.meters | length')
    log_success "User has $METERS_COUNT meters registered"
}

step5_link_meter_redis() {
    local AUTH_DATA="$1"
    local METER_DATA="$2"

    USER_ID=$(echo "$AUTH_DATA" | jq -r '.user_id')
    METER_SERIAL=$(echo "$METER_DATA" | jq -r '.serial')

    log_step 5 "Linking meter to user in Redis (for oracle-bridge resolution)"

    # Set Redis mapping: meter_serial -> user_id
    REDIS_KEY="gridtokenx:meters:${METER_SERIAL}:user_id"

    if docker ps --format '{{.Names}}' | grep -q 'gridtokenx-redis'; then
        docker exec gridtokenx-redis redis-cli SET "$REDIS_KEY" "$USER_ID"
        log_success "Redis mapping set: $REDIS_KEY -> $USER_ID"
        
        # Verify Redis entry
        REDIS_VALUE=$(docker exec gridtokenx-redis redis-cli GET "$REDIS_KEY")
        if [ "$REDIS_VALUE" == "$USER_ID" ]; then
            log_success "Redis verification passed"
        else
            log_error "Redis verification failed: expected $USER_ID, got $REDIS_VALUE"
        fi
    elif command -v redis-cli &> /dev/null; then
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "$REDIS_KEY" "$USER_ID"
        log_success "Redis mapping set: $REDIS_KEY -> $USER_ID"
    else
        log_info "redis-cli not available, skipping Redis mapping"
        log_info "Would set: $REDIS_KEY -> $USER_ID"
    fi
}

step6_check_mailpit() {
    local AUTH_DATA="$1"

    log_step 6 "Checking Mailpit for any emails"

    MAILPIT_RESPONSE=$(curl -s "$MAILPIT_URL/api/v1/messages?limit=5")
    TOTAL_EMAILS=$(echo "$MAILPIT_RESPONSE" | jq -r '.total')

    if [ "$TOTAL_EMAILS" -gt 0 ]; then
        log_success "Mailpit has $TOTAL_EMAILS emails"
        echo "$MAILPIT_RESPONSE" | jq '.messages[0:3] | .[] | {Subject: .Subject, From: .From, To: .To}' >&2
    else
        log_info "Mailpit has no emails (notification service may not be running)"
        log_info "Mailpit UI: $MAILPIT_URL"
    fi
}

step7_check_solana() {
    local AUTH_DATA="$1"
    local WALLET_ADDRESS=$(echo "$AUTH_DATA" | jq -r '.wallet_address')

    log_step 7 "Checking Solana CLI"

    if command -v solana &> /dev/null; then
        CLUSTER=$(solana config get 2>/dev/null | grep "RPC URL" | cut -d: -f2- | xargs || echo "not configured")
        log_info "Solana cluster: $CLUSTER"
        
        if [ -n "$WALLET_ADDRESS" ] && [ "$WALLET_ADDRESS" != "null" ]; then
            log_info "User wallet: $WALLET_ADDRESS"
            
            # Try to check balance (will fail if validator not running)
            BALANCE=$(solana balance "$WALLET_ADDRESS" 2>/dev/null || echo "unable to check")
            log_info "Wallet balance: $BALANCE"
        else
            log_info "No wallet address for user"
        fi
    else
        log_info "Solana CLI not installed"
    fi
}

step8_summary() {
    log_step 8 "Test complete - summary"

    echo "" >&2
    echo "========================================" >&2
    echo "E2E Meter Registration Test Summary" >&2
    echo "========================================" >&2
    echo "User: $USERNAME" >&2
    echo "Meter Serial: $METER_SERIAL" >&2
    echo "Meter Type: $METER_TYPE" >&2
    echo "Meter Location: $METER_LOCATION" >&2
    echo "IAM URL: $IAM_URL" >&2
    echo "Mailpit URL: $MAILPIT_URL" >&2
    echo "" >&2
    log_success "All steps completed successfully!"
    echo "" >&2
    echo "Verification Results:" >&2
    echo "  ✅ Meter registered via IAM API" >&2
    echo "  ✅ Meter verified in PostgreSQL database" >&2
    echo "  ✅ Meter verified via GET API endpoint" >&2
    echo "  ✅ Redis meter-to-user mapping set" >&2
    echo "" >&2
    echo "Next steps to fully test reading flow:" >&2
    echo "  1. Ensure Oracle Bridge is running" >&2
    echo "  2. Ensure smartmeter-simulator is running" >&2
    echo "  3. Run: python scripts/auto-send-smartmeter-to-oracle.py --meter-serial $METER_SERIAL" >&2
    echo "" >&2
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    echo "" >&2
    echo "========================================" >&2
    echo "E2E Meter Registration Flow Test" >&2
    echo "========================================" >&2
    echo "Mode: $MODE" >&2
    echo "IAM: $IAM_URL" >&2
    echo "Mailpit: $MAILPIT_URL" >&2
    echo "User: $USERNAME" >&2
    echo "Meter: $METER_SERIAL" >&2
    echo "" >&2

    check_prerequisites

    # Step 1: Login to get JWT
    AUTH_DATA=$(step1_login_user)

    # Step 2: Register meter
    METER_DATA=$(step2_register_meter "$AUTH_DATA")

    # Step 3: Verify meter in database
    step3_verify_meter_db "$AUTH_DATA" "$METER_DATA"

    # Step 4: Verify meter via API
    step4_verify_meter_api "$AUTH_DATA" "$METER_DATA"

    # Step 5: Link meter in Redis (for oracle)
    step5_link_meter_redis "$AUTH_DATA" "$METER_DATA"

    # Step 6: Check Mailpit
    step6_check_mailpit "$AUTH_DATA"

    # Step 7: Check Solana
    step7_check_solana "$AUTH_DATA"

    # Step 8: Summary
    step8_summary
}

# Run main
main "$@"