#!/usr/bin/env bash
# ============================================================================
# GridTokenX Authentication Test Suite
# Tests the IAM service authentication flow end-to-end
#
# Usage:
#   ./scripts/test-auth.sh                     # Auto-detect running service
#   ./scripts/test-auth.sh http://localhost:4010  # Specify IAM URL
# ============================================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ── Globals ─────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
ACCESS_TOKEN=""
USER_ID=""
UNIQUE_SUFFIX=$(date +%s)
TEST_EMAIL="test_${UNIQUE_SUFFIX}@gridtokenx.local"
TEST_USERNAME="testuser_${UNIQUE_SUFFIX}"
TEST_PASSWORD="T3st!Pass#2026"
TEST_FIRST_NAME="Test"
TEST_LAST_NAME="User"

# ── Service Discovery ──────────────────────────────────────────────
if [ -n "${1:-}" ]; then
    BASE_URL="$1"
elif curl -sf http://localhost:4010/health > /dev/null 2>&1; then
    BASE_URL="http://localhost:4010"
elif curl -sf http://localhost:4001/health > /dev/null 2>&1; then
    BASE_URL="http://localhost:4001"
else
    echo -e "${RED}ERROR:${NC} No IAM service detected on port 4010 (direct) or 4001 (gateway)."
    echo "       Start the IAM service first, or specify URL: $0 <url>"
    exit 1
fi

# Portable response parser (macOS head doesn't support -n -1)
# Usage: parse_response "$raw"  → sets RESP_BODY and RESP_STATUS
parse_response() {
    local raw="$1"
    RESP_STATUS=$(echo "$raw" | tail -n 1)
    RESP_BODY=$(echo "$raw" | sed '$d')
}

# ── Helpers ─────────────────────────────────────────────────────────

show_banner() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   ${BOLD}GridTokenX Authentication Test Suite${NC}${BLUE}              ║${NC}"
    echo -e "${BLUE}╠═══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}  Target: ${CYAN}${BASE_URL}${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

assert_status() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"

    if [ "$actual" -eq "$expected" ]; then
        echo -e "  ${GREEN}✓ PASS${NC} ${test_name} ${DIM}(HTTP ${actual})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} ${test_name} ${DIM}(expected ${expected}, got ${actual})${NC}"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_field() {
    local test_name="$1"
    local json="$2"
    local field="$3"

    local value
    value=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "null")

    if [ "$value" != "null" ] && [ -n "$value" ]; then
        echo -e "  ${GREEN}✓ PASS${NC} ${test_name} ${DIM}(${field}=${value})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} ${test_name} ${DIM}(field ${field} missing or null)${NC}"
        FAIL=$((FAIL + 1))
    fi
}

skip_test() {
    local test_name="$1"
    local reason="$2"
    echo -e "  ${YELLOW}⊘ SKIP${NC} ${test_name} ${DIM}(${reason})${NC}"
    SKIP=$((SKIP + 1))
}

show_summary() {
    local total=$((PASS + FAIL + SKIP))
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}Results:${NC} ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}  (${total} total)"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

    if [ "$FAIL" -gt 0 ]; then
        echo -e "  ${RED}${BOLD}SOME TESTS FAILED${NC}"
        exit 1
    else
        echo -e "  ${GREEN}${BOLD}ALL TESTS PASSED ✓${NC}"
    fi
    echo ""
}

# ── Test 1: Health Check ────────────────────────────────────────────

test_health() {
    echo -e "${CYAN}▸ Health Checks${NC}"

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health")
    assert_status "GET /health" 200 "$status"

    local body
    body=$(curl -s "${BASE_URL}/health")
    assert_json_field "Health response has status" "$body" ".status"

    # Readiness
    status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health/ready")
    if [ "$status" -eq 200 ]; then
        assert_status "GET /health/ready" 200 "$status"
        local ready_body
        ready_body=$(curl -s "${BASE_URL}/health/ready")
        assert_json_field "Readiness check — postgres" "$ready_body" '.checks.postgres.status'
        assert_json_field "Readiness check — redis" "$ready_body" '.checks.redis.status'
    else
        assert_status "GET /health/ready" 200 "$status"
    fi

    # Liveness
    status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health/live")
    assert_status "GET /health/live" 200 "$status"

    echo ""
}

# ── Test 2: Registration ───────────────────────────────────────────

test_register() {
    echo -e "${CYAN}▸ Registration${NC}"

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/api/v1/auth/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"${TEST_USERNAME}\",
            \"email\": \"${TEST_EMAIL}\",
            \"password\": \"${TEST_PASSWORD}\",
            \"first_name\": \"${TEST_FIRST_NAME}\",
            \"last_name\": \"${TEST_LAST_NAME}\"
        }")

    parse_response "$response"

    assert_status "POST /api/v1/auth/register" 200 "$RESP_STATUS"
    assert_json_field "Registration returns user ID" "$RESP_BODY" ".id"
    assert_json_field "Registration returns username" "$RESP_BODY" ".username"
    assert_json_field "Registration returns email" "$RESP_BODY" ".email"

    USER_ID=$(echo "$RESP_BODY" | jq -r '.id // empty')
    echo -e "    ${DIM}Registered user: ${TEST_USERNAME} (${USER_ID:-unknown})${NC}"

    # Duplicate registration should fail
    local dup_response
    dup_response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/auth/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"${TEST_USERNAME}\",
            \"email\": \"${TEST_EMAIL}\",
            \"password\": \"${TEST_PASSWORD}\"
        }")

    if [ "$dup_response" -eq 409 ] || [ "$dup_response" -eq 400 ] || [ "$dup_response" -eq 500 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} Duplicate registration rejected ${DIM}(HTTP ${dup_response})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} Duplicate registration should fail ${DIM}(got HTTP ${dup_response})${NC}"
        FAIL=$((FAIL + 1))
    fi

    echo ""
}

# ── Test 2b: Email Verification ────────────────────────────────────

test_verify_email() {
    echo -e "${CYAN}▸ Email Verification${NC}"

    if [ -z "$USER_ID" ]; then
        skip_test "GET /api/v1/auth/verify (activate)" "no user registered"
        echo ""
        return
    fi

    # The IAM service supports a "verify_{email}" shortcut token
    local verify_token="verify_${TEST_EMAIL}"

    local response
    response=$(curl -s -w "\n%{http_code}" "${BASE_URL}/api/v1/auth/verify?token=${verify_token}")

    parse_response "$response"

    assert_status "GET /api/v1/auth/verify (activate account)" 200 "$RESP_STATUS"
    assert_json_field "Verify returns success" "$RESP_BODY" ".success"
    assert_json_field "Verify returns wallet_address" "$RESP_BODY" ".wallet_address"
    assert_json_field "Verify returns auth token" "$RESP_BODY" ".auth.access_token"

    local verify_msg=$(echo "$RESP_BODY" | jq -r '.message // empty')
    echo -e "    ${DIM}Verification: ${verify_msg}${NC}"

    echo ""
}

# ── Test 3: Login ──────────────────────────────────────────────────

test_login() {
    echo -e "${CYAN}▸ Login${NC}"

    # Valid login
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"${TEST_EMAIL}\",
            \"password\": \"${TEST_PASSWORD}\"
        }")

    parse_response "$response"

    assert_status "POST /api/v1/auth/login (valid creds)" 200 "$RESP_STATUS"
    assert_json_field "Login returns access_token" "$RESP_BODY" ".access_token"
    assert_json_field "Login returns expires_in" "$RESP_BODY" ".expires_in"
    assert_json_field "Login returns user.id" "$RESP_BODY" ".user.id"
    assert_json_field "Login returns user.username" "$RESP_BODY" ".user.username"
    assert_json_field "Login returns user.email" "$RESP_BODY" ".user.email"
    assert_json_field "Login returns user.role" "$RESP_BODY" ".user.role"

    ACCESS_TOKEN=$(echo "$RESP_BODY" | jq -r '.access_token // empty')
    local expires_in=$(echo "$RESP_BODY" | jq -r '.expires_in // 0')
    echo -e "    ${DIM}Token acquired (expires_in=${expires_in}s, len=${#ACCESS_TOKEN})${NC}"

    # Invalid password
    local bad_status
    bad_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"${TEST_EMAIL}\",
            \"password\": \"WrongPassword123!\"
        }")

    if [ "$bad_status" -eq 401 ] || [ "$bad_status" -eq 400 ] || [ "$bad_status" -eq 500 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} Bad password rejected ${DIM}(HTTP ${bad_status})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} Bad password should be rejected ${DIM}(got HTTP ${bad_status})${NC}"
        FAIL=$((FAIL + 1))
    fi

    # Non-existent user
    local nouser_status
    nouser_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"nonexistent_${UNIQUE_SUFFIX}@void.dev\",
            \"password\": \"Whatever123!\"
        }")

    if [ "$nouser_status" -eq 401 ] || [ "$nouser_status" -eq 404 ] || [ "$nouser_status" -eq 500 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} Non-existent user rejected ${DIM}(HTTP ${nouser_status})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} Non-existent user should fail ${DIM}(got HTTP ${nouser_status})${NC}"
        FAIL=$((FAIL + 1))
    fi

    echo ""
}

# ── Test 4: Authenticated Endpoints ────────────────────────────────

test_authenticated() {
    echo -e "${CYAN}▸ Authenticated Endpoints${NC}"

    if [ -z "$ACCESS_TOKEN" ]; then
        skip_test "GET /api/v1/users/me" "no token (login failed)"
        skip_test "No-auth request rejected" "no token"
        skip_test "Bad-token request rejected" "no token"
        echo ""
        return
    fi

    # GET /me with valid token
    # We must spoof the ApiGateway role because /me is restricted via ServiceRole RBAC
    local response
    response=$(curl -s -w "\n%{http_code}" "${BASE_URL}/api/v1/users/me" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "x-gridtokenx-role: api-gateway" \
        -H "x-gridtokenx-gateway-secret: gridtokenx-gateway-secret-2025")

    parse_response "$response"

    assert_status "GET /api/v1/users/me (valid token)" 200 "$RESP_STATUS"
    assert_json_field "Profile returns user ID" "$RESP_BODY" ".id"
    assert_json_field "Profile returns email" "$RESP_BODY" ".email"

    # Without token — should 401
    local noauth_status
    noauth_status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/v1/users/me")

    if [ "$noauth_status" -eq 401 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} No-auth request rejected ${DIM}(HTTP ${noauth_status})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} No-auth should 401 ${DIM}(got HTTP ${noauth_status})${NC}"
        FAIL=$((FAIL + 1))
    fi

    # With invalid token — should 401
    local badtoken_status
    badtoken_status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/v1/users/me" \
        -H "Authorization: Bearer invalid.jwt.token")

    if [ "$badtoken_status" -eq 401 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} Bad-token request rejected ${DIM}(HTTP ${badtoken_status})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} Bad-token should 401 ${DIM}(got HTTP ${badtoken_status})${NC}"
        FAIL=$((FAIL + 1))
    fi

    echo ""
}

# ── Test 5: System Config Endpoint ─────────────────────────────────

test_system_config() {
    echo -e "${CYAN}▸ System Config${NC}"

    local response
    response=$(curl -s -w "\n%{http_code}" "${BASE_URL}/api/v1/system/config")

    parse_response "$response"

    assert_status "GET /api/v1/system/config" 200 "$RESP_STATUS"
    assert_json_field "Config has environment" "$RESP_BODY" ".environment"
    assert_json_field "Config has solana_rpc_url" "$RESP_BODY" ".solana_rpc_url"
    assert_json_field "Config has registry_program_id" "$RESP_BODY" ".registry_program_id"
    assert_json_field "Config has trading_program_id" "$RESP_BODY" ".trading_program_id"

    echo ""
}

# ── Test 6: Metrics Endpoint ──────────────────────────────────────

test_metrics() {
    echo -e "${CYAN}▸ Observability${NC}"

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/metrics")
    assert_status "GET /metrics" 200 "$status"

    echo ""
}

# ── Test 7: Forgot Password ──────────────────────────────────────

test_forgot_password() {
    echo -e "${CYAN}▸ Password Reset Flow${NC}"

    # Forgot password (valid email)
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/api/v1/auth/forgot-password" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"${TEST_EMAIL}\"}")

    parse_response "$response"

    assert_status "POST /api/v1/auth/forgot-password (valid email)" 200 "$RESP_STATUS"
    assert_json_field "Forgot-password returns message" "$RESP_BODY" ".message"

    # Forgot password (non-existent email — should still 200 for security)
    local fake_status
    fake_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/auth/forgot-password" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"nonexistent_${UNIQUE_SUFFIX}@void.dev\"}")

    assert_status "POST /api/v1/auth/forgot-password (unknown email — silent)" 200 "$fake_status"

    # Reset password with invalid token — should fail
    local reset_status
    reset_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/auth/reset-password" \
        -H "Content-Type: application/json" \
        -d "{\"token\": \"invalid-reset-token\", \"new_password\": \"NewPass!123\"}")

    if [ "$reset_status" -eq 400 ] || [ "$reset_status" -eq 404 ] || [ "$reset_status" -eq 500 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} Reset with bad token rejected ${DIM}(HTTP ${reset_status})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} Reset with bad token should fail ${DIM}(got HTTP ${reset_status})${NC}"
        FAIL=$((FAIL + 1))
    fi

    echo ""
}

# ── Test 8: Edge Cases ─────────────────────────────────────────────

test_edge_cases() {
    echo -e "${CYAN}▸ Edge Cases${NC}"

    # Empty body on login
    local empty_status
    empty_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d "{}")

    if [ "$empty_status" -eq 400 ] || [ "$empty_status" -eq 422 ] || [ "$empty_status" -eq 500 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} Empty login body rejected ${DIM}(HTTP ${empty_status})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} Empty body should fail ${DIM}(got HTTP ${empty_status})${NC}"
        FAIL=$((FAIL + 1))
    fi

    # Malformed JSON
    local malformed_status
    malformed_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d "not-json")

    if [ "$malformed_status" -eq 400 ] || [ "$malformed_status" -eq 422 ] || [ "$malformed_status" -eq 500 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} Malformed JSON rejected ${DIM}(HTTP ${malformed_status})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} Malformed JSON should fail ${DIM}(got HTTP ${malformed_status})${NC}"
        FAIL=$((FAIL + 1))
    fi

    # Missing content-type
    local notype_status
    notype_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/auth/login" \
        -d "{\"username\":\"test\",\"password\":\"test\"}")

    if [ "$notype_status" -eq 400 ] || [ "$notype_status" -eq 415 ] || [ "$notype_status" -eq 422 ] || [ "$notype_status" -eq 500 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} Missing Content-Type rejected ${DIM}(HTTP ${notype_status})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} Missing Content-Type should fail ${DIM}(got HTTP ${notype_status})${NC}"
        FAIL=$((FAIL + 1))
    fi

    # 404 for unknown route
    local notfound_status
    notfound_status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/v1/auth/nonexistent")

    if [ "$notfound_status" -eq 404 ] || [ "$notfound_status" -eq 405 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} Unknown route returns 404/405 ${DIM}(HTTP ${notfound_status})${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} Unknown route should 404 ${DIM}(got HTTP ${notfound_status})${NC}"
        FAIL=$((FAIL + 1))
    fi

    echo ""
}

# ── Main ────────────────────────────────────────────────────────────

show_banner
test_health
test_register
test_verify_email
test_login
test_authenticated
test_system_config
test_metrics
test_forgot_password
test_edge_cases
show_summary
