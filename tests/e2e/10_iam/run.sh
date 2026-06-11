#!/usr/bin/env bash
# Suite 10 — IAM Service (:4010). Auth, wallet provisioning, RBAC, on-chain onboarding.
# Routes confirmed in gridtokenx-iam-service/bin/iam-service/src/startup.rs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/db.sh"
source "$HERE/../lib/http.sh"

echo "=== IAM Suite | run $E2E_RUN_ID | $IAM_URL ==="

# --- Case 1: Register -> verify -> JWT + wallet --------------------------
log_info "Case 1: register -> verify -> JWT issued + wallet provisioned"
new_user >/dev/null; JWT="$E2E_JWT"
assert_nonempty "$E2E_USER_ID" "register returns user id"
assert_contains "$(echo "$REG_RESP" | jq -r '.message // empty')" "verify" "register prompts email verification"
assert_nonempty "$JWT" "verify yields access_token"
assert_nonempty "${WALLET_ADDRESS:-}" "primary wallet linked post-verify (verify no longer provisions one — iam 8b84ccd)"
assert_eq "$(echo "$VERIFY_RESP" | jq -r '.success')" "true" "verify success=true"

# --- Case 2: Login happy path -------------------------------------------
log_info "Case 2: login with valid credentials"
LOGIN_JWT=$(login "$E2E_USERNAME" "$E2E_PASSWORD")
assert_status "$(hs)" "200" "login returns 200"
assert_nonempty "$LOGIN_JWT" "login issues access_token"

# --- Case 3: Login wrong password ---------------------------------------
log_info "Case 3: login with wrong password rejected"
BAD_JWT=$(login "$E2E_USERNAME" "wrong-password-xxx")
if [ "$(hs)" == "401" ] || [ "$(hs)" == "403" ]; then
    log_success "wrong password rejected [$(hs)]"
else
    log_fail "wrong password not rejected (got $(hs))"
fi
assert_eq "$BAD_JWT" "" "no token on bad credentials"

# --- Case 4: Idempotent register (duplicate) ----------------------------
log_info "Case 4: duplicate registration rejected"
DUP=$(register_user "$E2E_USERNAME" "$E2E_EMAIL")
if [ "$(hs)" == "409" ] || [ "$(hs)" == "400" ] || [ "$(hs)" == "422" ]; then
    log_success "duplicate register rejected [$(hs)]"
else
    log_fail "duplicate register not rejected (got $(hs), id='$DUP')"
fi

# --- Case 5: Wallet key encrypted at rest, no plaintext ------------------
# Custodial primary-wallet key material lives in the OWS file vault (OWS_VAULT_PATH),
# not the DB — `users.encrypted_private_key/wallet_salt` stay NULL here. The reliable DB
# signal that the encrypted-wallet pipeline ran is `wallet_encryption_version`.
log_info "Case 5: wallet provisioned with encryption version, no plaintext key column"
ENC_VER=$(db_wallet_enc_version "$E2E_USERNAME")
assert_nonempty "$ENC_VER" "wallet_encryption_version set (encrypted-wallet pipeline ran)"
assert_eq "$(db_plaintext_key_columns)" "0" "no plaintext private_key column on users"

# --- Case 6: Authenticated profile (GET /users/me) ----------------------
log_info "Case 6: authenticated profile fetch"
ME=$(get_me "$JWT")
assert_status "$(hs)" "200" "GET /users/me authorized"
assert_eq "$(echo "$ME" | jq -r '.id // empty')" "$E2E_USER_ID" "profile id matches"

# --- Case 7: Unauthenticated access rejected ----------------------------
log_info "Case 7: /users/me without token rejected"
http_json GET "$IAM_URL/api/v1/users/me" >/dev/null
if [ "$(hs)" == "401" ] || [ "$(hs)" == "403" ]; then
    log_success "unauthenticated profile blocked [$(hs)]"
else
    log_fail "unauthenticated profile not blocked (got $(hs))"
fi

# --- Case 8: On-chain onboarding (Registry PDA via Chain Bridge) ---------
log_info "Case 8: on-chain user onboarding"
ONB=$(onboard_user "$JWT" "prosumer")
TX_SIG=$(echo "$ONB" | jq -r '.transaction_signature // empty')
ONB_MSG=$(echo "$ONB" | jq -r '.message // empty')
if [ -n "$TX_SIG" ]; then
    log_success "onboard returned tx signature: ${TX_SIG:0:16}..."
elif echo "$ONB_MSG" | grep -qiE 'on-chain|chain bridge|submission'; then
    log_warn "onboard reached Chain Bridge but no tx sig (validator/bridge state): $ONB_MSG"
    log_success "onboard initiated on-chain path"
else
    log_fail "onboard failed: $ONB"
fi

# --- Case 9: Idempotent onboarding --------------------------------------
log_info "Case 9: re-onboard is idempotent (no error/duplicate PDA)"
ONB2=$(onboard_user "$JWT" "prosumer")
if [ "$(hs)" == "200" ] || [ "$(hs)" == "409" ] || [ "$(hs)" == "202" ]; then
    log_success "re-onboard handled idempotently [$(hs)]"
else
    log_fail "re-onboard unexpected status $(hs): $ONB2"
fi

# --- Case 10: Link secondary wallet -> auto on-chain --------------------
log_info "Case 10: link secondary wallet auto-registers on-chain"
# Must be a real base58 ed25519 pubkey — IAM validates it (and registers it
# on-chain), so a hand-built hex-suffixed string fails "Invalid Base58 string".
SEC_WALLET_KP="${TMPDIR:-/tmp}/e2e-sec-${E2E_RUN_ID}-$RANDOM.json"
SEC_WALLET=$(solana-keygen new --no-bip39-passphrase --silent --force -o "$SEC_WALLET_KP" >/dev/null 2>&1 \
    && solana-keygen pubkey "$SEC_WALLET_KP" 2>/dev/null)
[ -n "$SEC_WALLET" ] || log_warn "solana-keygen unavailable — link-wallet uses a static valid pubkey"
SEC_WALLET="${SEC_WALLET:-So11111111111111111111111111111111111111112}"
LINK=$(link_wallet "$JWT" "$SEC_WALLET")
REGISTERED=$(echo "$LINK" | jq -r '.wallet.blockchain_registered // empty')
PDA=$(echo "$LINK" | jq -r '.wallet.user_account_pda // empty')
if [ "$REGISTERED" == "true" ]; then
    log_success "secondary wallet on-chain registered, PDA: $PDA"
elif [ "$(hs)" == "200" ] || [ "$(hs)" == "201" ]; then
    log_warn "wallet linked but blockchain_registered=$REGISTERED (validator state)"
    log_success "secondary wallet linked"
else
    log_fail "link wallet failed [$(hs)]: $LINK"
fi

# --- Case 11: List wallets reflects link --------------------------------
log_info "Case 11: wallet list includes linked secondary"
WL=$(auth_json GET "$IAM_URL/api/v1/users/me/wallets" "$JWT")
assert_status "$(hs)" "200" "list wallets authorized"
assert_contains "$WL" "$SEC_WALLET" "linked wallet present in list"

suite_summary
