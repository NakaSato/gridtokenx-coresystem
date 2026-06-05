#!/bin/bash

# GridTokenX — prosumer1 registration + email verification + wallet address.
# Flow: Register -> read verification token from Postgres -> Verify (provisions
# the Vault wallet) -> print the provisioned Solana wallet address.
#
# Idempotent on the account: a fixed username/email means re-runs hit HTTP 409
# "already exists"; we then re-read the user id from the DB and (if still
# unverified) re-verify to recover the wallet address.
#
# Usage:
#   scripts/test-prosumer1.sh
#   API_URL=http://localhost:4010 scripts/test-prosumer1.sh   # hit IAM directly
set -euo pipefail

API_URL="${API_URL:-http://localhost:4001}"
DB_CONTAINER="${DB_CONTAINER:-gridtokenx-postgres}"
DB_USER="${DB_USER:-gridtokenx_user}"
DB_NAME="${DB_NAME:-gridtokenx}"

USERNAME="${USERNAME:-prosumer1}"
EMAIL="${EMAIL:-prosumer1@grx.test}"
PASSWORD="${PASSWORD:-Prosumer1!2026!Grid}"

# IAM normally receives these from APISIX; presented here so the script works
# whether it targets the gateway (:4001) or IAM directly (:4010).
GW_ROLE_HDR="x-gridtokenx-role: api-gateway"
GW_SECRET_HDR="x-gridtokenx-gateway-secret: ${GATEWAY_SECRET:-gridtokenx-gateway-secret-2025}"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

for cmd in jq docker curl; do
  command -v "$cmd" >/dev/null 2>&1 || log_err "$cmd is required."
done

db_q() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "$1" | tr -d '[:space:]'; }

echo "--------------------------------------------------"
echo "🔌 prosumer1 register + verify + wallet"
echo "API: $API_URL   user: $USERNAME   email: $EMAIL"
echo "--------------------------------------------------"

# 1. Register
log_info "Step 1: register $USERNAME"
REG_RESP=$(curl -s -o /tmp/p1_reg.json -w "%{http_code}" -X POST "$API_URL/api/v1/auth/register" \
  -H "Content-Type: application/json" -H "$GW_ROLE_HDR" -H "$GW_SECRET_HDR" \
  -d "{\"email\":\"$EMAIL\",\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\",\"first_name\":\"Pro\",\"last_name\":\"Sumer\"}")
REG_BODY=$(cat /tmp/p1_reg.json)

if [ "$REG_RESP" = "200" ] || [ "$REG_RESP" = "201" ]; then
  USER_ID=$(echo "$REG_BODY" | jq -r '.id // empty')
  log_ok "registered, user_id=$USER_ID (state: inactive)"
elif [ "$REG_RESP" = "409" ]; then
  log_warn "already exists (409) — recovering from DB"
  USER_ID=$(db_q "SELECT id FROM users WHERE username='$USERNAME' OR email='$EMAIL' LIMIT 1;")
  [ -n "$USER_ID" ] || log_err "409 but no row found for $USERNAME/$EMAIL"
  log_ok "recovered user_id=$USER_ID"
else
  log_err "register HTTP $REG_RESP: $REG_BODY"
fi

# 2. Read verification token from DB
log_info "Step 2: read email_verification_token from DB"
VERIFY_TOKEN=$(db_q "SELECT email_verification_token FROM users WHERE id='$USER_ID';")
ALREADY_VERIFIED=$(db_q "SELECT email_verified FROM users WHERE id='$USER_ID';")

# 3. Verify (provisions the Vault wallet) — extract wallet from the response
WALLET=""
JWT=""
if [ -n "$VERIFY_TOKEN" ] && [ "$VERIFY_TOKEN" != "(0rows)" ]; then
  log_info "Step 3: verify email (token ${VERIFY_TOKEN:0:8}...)"
  VERIFY_RESP=$(curl -s -X GET "$API_URL/api/v1/auth/verify?token=$VERIFY_TOKEN" \
    -H "$GW_ROLE_HDR" -H "$GW_SECRET_HDR")
  if [ "$(echo "$VERIFY_RESP" | jq -r '.success // empty')" = "true" ]; then
    WALLET=$(echo "$VERIFY_RESP" | jq -r '.wallet_address // empty')
    JWT=$(echo "$VERIFY_RESP" | jq -r '.auth.access_token // empty')
    log_ok "email verified + wallet provisioned"
  else
    log_err "verify failed: $VERIFY_RESP"
  fi
else
  log_warn "no pending token (email_verified=$ALREADY_VERIFIED) — already verified; logging in"
  LOGIN_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" -H "$GW_ROLE_HDR" -H "$GW_SECRET_HDR" \
    -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")
  JWT=$(echo "$LOGIN_RESP" | jq -r '.access_token // .auth.access_token // empty')
  [ -n "$JWT" ] || log_err "login failed: $LOGIN_RESP"
fi

# 4. Resolve wallet address (from verify, else list wallets, else DB)
if [ -z "$WALLET" ] && [ -n "$JWT" ]; then
  log_info "Step 4: fetch wallet via /api/v1/me/wallets"
  WALLETS_RESP=$(curl -s -X GET "$API_URL/api/v1/me/wallets" \
    -H "Authorization: Bearer $JWT" -H "$GW_ROLE_HDR" -H "$GW_SECRET_HDR")
  WALLET=$(echo "$WALLETS_RESP" | jq -r '(.wallets // .)[0].wallet_address // (.wallets // .)[0].address // empty' 2>/dev/null || true)
fi
if [ -z "$WALLET" ]; then
  WALLET=$(db_q "SELECT wallet_address FROM users WHERE id='$USER_ID';")
fi

echo "--------------------------------------------------"
echo "Username:       $USERNAME"
echo "User ID:        $USER_ID"
echo "Email verified: $(db_q "SELECT email_verified FROM users WHERE id='$USER_ID';")"
echo "Wallet address: ${WALLET:-<none>}"
echo "--------------------------------------------------"
[ -n "$WALLET" ] && [ "$WALLET" != "null" ] || log_err "no wallet address resolved"
log_ok "🏆 prosumer1 verified — wallet $WALLET"
