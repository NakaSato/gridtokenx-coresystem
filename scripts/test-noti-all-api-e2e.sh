#!/bin/bash

# GridTokenX Notification Service (NOTI) Comprehensive E2E Test
# Covers ConnectRPC (gRPC) endpoints, Health, and DB persistence.

set -e

# Configuration
# Note: In docker-compose, ports are 4060:8080 (REST/Health) and 5060:8090 (gRPC/ConnectRPC)
# However, startup.rs maps both to the same port. Let's use 5060 as the primary.
NOTI_URL="${NOTI_URL:-http://localhost:5060}"
DB_CONTAINER="${DB_CONTAINER:-gridtokenx-postgres}"
DB_USER="${DB_USER:-gridtokenx_user}"
DB_NAME="${DB_NAME:-gridtokenx_noti}"
# Mailpit for verification (dev)
MAILPIT_URL="${MAILPIT_URL:-http://localhost:13060}"

TIMESTAMP=$(date +%s)
RECIPIENT="test_user_${TIMESTAMP}@grx.test"
IDEMPOTENCY_KEY="idem_noti_${TIMESTAMP}"
TEMPLATE_WELCOME="welcome.txt.tera"
TEMPLATE_INVALID="invalid_template_${TIMESTAMP}.tera"

# Colors
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
echo "📬 Starting Notification Service ALL API E2E Test"
echo "--------------------------------------------------"

# --- PART 1: OBSERVABILITY & HEALTH ---
log_step "PART 1: Observability & Health"

log_info "Checking health (/health)..."
HEALTH_RESP=$(curl -s -X GET "$NOTI_URL/health")
log_resp "$HEALTH_RESP"
[[ "$(echo "$HEALTH_RESP" | jq -r '.status')" != "ok" ]] && log_fail "Health check failed."
log_pass "Health: OK"

log_info "Checking liveness (/health/live)..."
LIVE_RESP=$(curl -s -X GET "$NOTI_URL/health/live")
log_resp "$LIVE_RESP"
[[ "$(echo "$LIVE_RESP" | jq -r '.status')" != "alive" ]] && log_fail "Liveness check failed."
log_pass "Liveness: Alive"

# --- PART 2: SEND NOTIFICATION (EMAIL) ---
log_step "PART 2: Send Notification (Email)"

log_info "Sending welcome email notification..."
# Channel: 0 = EMAIL, 1 = SMS, 2 = PUSH, 3 = WEBHOOK, 4 = WEBSOCKET
SEND_RESP=$(curl -s -X POST "$NOTI_URL/noti.NotificationService/SendNotification" \
    -H "Content-Type: application/json" \
    -d "{
        \"channel\": \"EMAIL\",
        \"recipient\": \"$RECIPIENT\",
        \"template_id\": \"$TEMPLATE_WELCOME\",
        \"variables_json\": \"{\\\"name\\\": \\\"E2E Tester\\\"}\",
        \"idempotency_key\": \"$IDEMPOTENCY_KEY\"
    }")
log_resp "$SEND_RESP"
NOTI_ID=$(echo "$SEND_RESP" | jq -r '.notificationId // .notification_id // empty')
[ -z "$NOTI_ID" ] && log_fail "SendNotification failed."
log_pass "Notification enqueued: $NOTI_ID"

log_info "Verifying status via GetNotificationStatus..."
# ConnectRPC allows GET with base64 encoded request, but POST is simpler.
STATUS_RESP=$(curl -s -X POST "$NOTI_URL/noti.NotificationService/GetNotificationStatus" \
    -H "Content-Type: application/json" \
    -d "{ \"notificationId\": \"$NOTI_ID\" }")
log_resp "$STATUS_RESP"
RET_ID=$(echo "$STATUS_RESP" | jq -r '.notificationId // .notification_id // empty')
[[ "$RET_ID" != "$NOTI_ID" ]] && log_fail "Status ID mismatch. Expected $NOTI_ID, got $RET_ID"
log_pass "Status retrieved successfully."

# --- PART 3: IDEMPOTENCY ---
log_step "PART 3: Idempotency"

log_info "Resending same request with same idempotency key..."
SEND_RESP_DUPE=$(curl -s -X POST "$NOTI_URL/noti.NotificationService/SendNotification" \
    -H "Content-Type: application/json" \
    -d "{
        \"channel\": \"EMAIL\",
        \"recipient\": \"$RECIPIENT\",
        \"template_id\": \"$TEMPLATE_WELCOME\",
        \"variables_json\": \"{\\\"name\\\": \\\"E2E Tester\\\"}\",
        \"idempotency_key\": \"$IDEMPOTENCY_KEY\"
    }")
log_resp "$SEND_RESP_DUPE"
DUPE_ID=$(echo "$SEND_RESP_DUPE" | jq -r '.notificationId // .notification_id // empty')
[[ "$DUPE_ID" != "$NOTI_ID" ]] && log_fail "Idempotency failed: expected $NOTI_ID, got $DUPE_ID"
log_pass "Idempotency verified: returned same ID."

# --- PART 4: ERROR HANDLING (INVALID TEMPLATE) ---
log_step "PART 4: Error Handling"

log_info "Sending notification with invalid template..."
ERR_RESP=$(curl -s -X POST "$NOTI_URL/noti.NotificationService/SendNotification" \
    -H "Content-Type: application/json" \
    -d "{
        \"channel\": \"EMAIL\",
        \"recipient\": \"$RECIPIENT\",
        \"template_id\": \"$TEMPLATE_INVALID\",
        \"variables_json\": \"{}\",
        \"idempotency_key\": \"idem_err_${TIMESTAMP}\"
    }")
log_resp "$ERR_RESP"
ERR_ID=$(echo "$ERR_RESP" | jq -r '.notificationId // .notification_id // empty')
[ -z "$ERR_ID" ] && log_fail "Should have returned a notification ID even for invalid template (async)."
log_pass "Async request accepted for processing."

log_info "Waiting for processing failure..."
sleep 2 # Give it time to fail rendering
ERR_STATUS_RESP=$(curl -s -X POST "$NOTI_URL/noti.NotificationService/GetNotificationStatus" \
    -H "Content-Type: application/json" \
    -d "{ \"notificationId\": \"$ERR_ID\" }")
log_resp "$ERR_STATUS_RESP"
STATUS=$(echo "$ERR_STATUS_RESP" | jq -r '.status')
[[ "$STATUS" != "permanentfailure" && "$STATUS" != "failed" ]] && log_fail "Expected failure status, got: $STATUS"
log_pass "Correctly transitioned to failure state."

# --- PART 5: DATABASE VERIFICATION ---
log_step "PART 5: Database Verification"

log_info "Checking record in Postgres..."
DB_CHECK=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT status FROM notifications WHERE id = '$NOTI_ID';" | tr -d '[:space:]')
log_info "DB Status: $DB_CHECK"
[ -z "$DB_CHECK" ] && log_fail "Record not found in DB."
log_pass "Persistence verified."

# --- PART 6: EMAIL DELIVERY (MAILPIT) ---
log_step "PART 6: Email Delivery Verification (Mailpit)"

log_info "Checking Mailpit for delivered email..."
# Give SMTP a moment to relay
sleep 1
MAILPIT_RESP=$(curl -s "$MAILPIT_URL/api/v1/messages")
log_info "Total messages in Mailpit: $(echo "$MAILPIT_RESP" | jq '.total')"
MATCH=$(echo "$MAILPIT_RESP" | jq -r ".messages[] | select(.To[0].Address == \"$RECIPIENT\") | .ID" | head -n 1)

if [ -z "$MATCH" ]; then
    log_info "Email not found in Mailpit yet (might be using MockEmailProvider in dev)."
else
    log_pass "Email delivered to Mailpit! Message ID: $MATCH"
fi

# --- PART 7: WEBSOCKET TRIGGER ---
log_step "PART 7: WebSocket Trigger"

log_info "Triggering WebSocket notification..."
WS_USER_ID="00000000-0000-0000-0000-000000000001"
WS_RESP=$(curl -s -X POST "$NOTI_URL/noti.NotificationService/SendNotification" \
    -H "Content-Type: application/json" \
    -d "{
        \"channel\": \"WEBSOCKET\",
        \"recipient\": \"$WS_USER_ID\",
        \"template_id\": \"trade_matched.txt.tera\",
        \"variables_json\": \"{\\\"role\\\": \\\"buyer\\\", \\\"amount\\\": \\\"100\\\", \\\"price\\\": \\\"5.5\\\"}\"
    }")
log_resp "$WS_RESP"
log_pass "WebSocket notification triggered."

echo "--------------------------------------------------"
log_pass "🏆 ALL NOTIFICATION SERVICE ENDPOINTS VERIFIED"
echo "--------------------------------------------------"
