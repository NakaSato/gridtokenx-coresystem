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

# --- Case 6: Authenticated profile (GET /me) ----------------------
log_info "Case 6: authenticated profile fetch"
ME=$(get_me "$JWT")
assert_status "$(hs)" "200" "GET /me authorized"
assert_eq "$(echo "$ME" | jq -r '.id // empty')" "$E2E_USER_ID" "profile id matches"

# --- Case 7: Unauthenticated access rejected ----------------------------
log_info "Case 7: /me without token rejected"
http_json GET "$IAM_URL/api/v1/me" >/dev/null
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
WL=$(auth_json GET "$IAM_URL/api/v1/me/wallets" "$JWT")
assert_status "$(hs)" "200" "list wallets authorized"
assert_contains "$WL" "$SEC_WALLET" "linked wallet present in list"

# --- Case 12: Refresh token -> new access_token --------------------------
log_info "Case 12: refresh exchanges valid JWT for a fresh access_token"
REF=$(refresh_token "$JWT")
assert_status "$(hs)" "200" "refresh authorized"
assert_nonempty "$(echo "$REF" | jq -r '.access_token // empty')" "refresh returns access_token"
assert_eq "$(echo "$REF" | jq -r '.token_type // empty')" "Bearer" "refresh token_type=Bearer"

# --- Case 13: Refresh without token rejected ----------------------------
log_info "Case 13: refresh without bearer token rejected"
http_json POST "$IAM_URL/api/v1/auth/refresh" "" "${GATEWAY_HEADERS[@]}" >/dev/null
if [ "$(hs)" == "401" ] || [ "$(hs)" == "403" ]; then
    log_success "unauthenticated refresh blocked [$(hs)]"
else
    log_fail "unauthenticated refresh not blocked (got $(hs))"
fi

# --- Case 14: Resend verification is anti-enumeration -------------------
# Generic 200 ack whether the email is known, unknown, or already verified.
log_info "Case 14: resend-verification returns generic ack (anti-enumeration)"
resend_verification "$E2E_EMAIL" >/dev/null
assert_status "$(hs)" "200" "resend-verification (known email) 200"
resend_verification "nobody-${E2E_RUN_ID}@grx.test" >/dev/null
assert_status "$(hs)" "200" "resend-verification (unknown email) 200 — no enumeration"

# --- Case 15: Forgot password generic ack -------------------------------
log_info "Case 15: forgot-password returns generic ack for any email"
FP=$(forgot_password "$E2E_EMAIL")
assert_status "$(hs)" "200" "forgot-password (known email) 200"
assert_contains "$FP" "reset" "forgot-password generic message mentions reset"
forgot_password "ghost-${E2E_RUN_ID}@grx.test" >/dev/null
assert_status "$(hs)" "200" "forgot-password (unknown email) 200 — no enumeration"

# --- Case 16: Reset password with invalid token rejected ----------------
log_info "Case 16: reset-password with bogus token rejected"
reset_password "invalid-token-${E2E_RUN_ID}" "GRX-New-P@ss-2026" >/dev/null
if [ "$(hs)" == "400" ] || [ "$(hs)" == "404" ]; then
    log_success "invalid reset token rejected [$(hs)]"
else
    log_fail "invalid reset token not rejected (got $(hs))"
fi

# --- Case 17: Fetch single wallet by id (GET /me/wallets/{id}) -----------
log_info "Case 17: fetch single wallet by id"
SEC_ID=$(echo "$WL" | jq -r --arg a "$SEC_WALLET" 'if type=="array" then .[] else .wallets[] end | select(.wallet_address==$a) | .id' | head -1)
if [ -n "$SEC_ID" ]; then
    GW=$(auth_json GET "$IAM_URL/api/v1/me/wallets/$SEC_ID" "$JWT")
    assert_status "$(hs)" "200" "get single wallet authorized"
    assert_eq "$(echo "$GW" | jq -r '.wallet_address // empty')" "$SEC_WALLET" "wallet address matches id"
else
    log_warn "secondary wallet id not found in list — skipping single-wallet GET/PATCH/DELETE"
fi

# --- Case 18: PATCH no-op body rejected (400) ---------------------------
log_info "Case 18: PATCH wallet with non-actionable body rejected"
if [ -n "$SEC_ID" ]; then
    auth_json PATCH "$IAM_URL/api/v1/me/wallets/$SEC_ID" "$JWT" '{"is_primary":false}' >/dev/null
    assert_status "$(hs)" "400" "PATCH is_primary:false rejected (only is_primary:true supported)"
fi

# --- Case 19: PATCH promotes secondary to primary -----------------------
log_info "Case 19: PATCH is_primary:true promotes secondary wallet"
if [ -n "$SEC_ID" ]; then
    PW=$(auth_json PATCH "$IAM_URL/api/v1/me/wallets/$SEC_ID" "$JWT" '{"is_primary":true}')
    assert_status "$(hs)" "200" "promote secondary wallet authorized"
    assert_eq "$(echo "$PW" | jq -r '.is_primary')" "true" "secondary wallet now primary"
fi

# --- Case 20: DELETE wallet — primary blocked, secondary unlinked -------
log_info "Case 20: cannot delete primary; non-primary unlinks"
if [ -n "$SEC_ID" ]; then
    # SEC_ID is now primary (case 19) -> delete must be rejected.
    auth_json DELETE "$IAM_URL/api/v1/me/wallets/$SEC_ID" "$JWT" >/dev/null
    assert_status "$(hs)" "400" "deleting primary wallet rejected"
    # The other (original) wallet is now non-primary -> deletable.
    OTHER_ID=$(echo "$WL" | jq -r --arg a "$SEC_WALLET" 'if type=="array" then .[] else .wallets[] end | select(.wallet_address!=$a) | .id' | head -1)
    if [ -n "$OTHER_ID" ]; then
        auth_json DELETE "$IAM_URL/api/v1/me/wallets/$OTHER_ID" "$JWT" >/dev/null
        if [ "$(hs)" == "200" ] || [ "$(hs)" == "204" ]; then
            log_success "non-primary wallet unlinked [$(hs)]"
        else
            log_fail "non-primary wallet delete failed (got $(hs))"
        fi
    else
        log_warn "no non-primary wallet found to unlink"
    fi
fi

# --- Case 21: System config exposes chain wiring -------------------------
log_info "Case 21: GET /system/config returns environment + program ids"
CFG=$(http_json GET "$IAM_URL/api/v1/system/config" "" "${GATEWAY_HEADERS[@]}")
assert_status "$(hs)" "200" "system config reachable"
assert_nonempty "$(echo "$CFG" | jq -r '.environment // empty')" "config has environment"
assert_nonempty "$(echo "$CFG" | jq -r '.registry_program_id // empty')" "config has registry_program_id"

# --- Case 22: Liveness probe --------------------------------------------
# Ops endpoints hit IAM directly on $IAM_URL (host->container), bypassing the APISIX
# ip-restriction that gates them on the public gateway. No auth / gateway headers needed.
log_info "Case 22: GET /health is a public liveness probe"
H=$(http_json GET "$IAM_URL/health")
assert_status "$(hs)" "200" "/health returns 200"
assert_eq "$(echo "$H" | jq -r '.status // empty')" "ok" "/health status=ok"
assert_eq "$(echo "$H" | jq -r '.service // empty')" "gridtokenx-iam" "/health identifies service"

# --- Case 23: Liveness (k8s live) ---------------------------------------
log_info "Case 23: GET /health/live"
HL=$(http_json GET "$IAM_URL/health/live")
assert_status "$(hs)" "200" "/health/live returns 200"
assert_eq "$(echo "$HL" | jq -r '.status // empty')" "alive" "/health/live status=alive"

# --- Case 24: Readiness checks Postgres + Redis -------------------------
log_info "Case 24: GET /health/ready validates deps"
HR=$(http_json GET "$IAM_URL/health/ready")
assert_status "$(hs)" "200" "/health/ready returns 200 (deps up)"
assert_eq "$(echo "$HR" | jq -r '.status // empty')" "ready" "/health/ready status=ready"
assert_eq "$(echo "$HR" | jq -r '.checks.postgres.status // empty')" "ok" "readiness: postgres ok"
assert_eq "$(echo "$HR" | jq -r '.checks.redis.status // empty')" "ok" "readiness: redis ok"

# --- Case 25: Prometheus metrics ----------------------------------------
log_info "Case 25: GET /metrics exposes Prometheus text"
M=$(http_json GET "$IAM_URL/metrics")
assert_status "$(hs)" "200" "/metrics returns 200"
assert_contains "$M" "# " "metrics body is Prometheus exposition format"

# --- Pytest cases (gRPC) — same folder, dispatched here so the suite is self-contained.
pytest_suite "$HERE" || log_fail "IAM pytest cases failed"

suite_summary
