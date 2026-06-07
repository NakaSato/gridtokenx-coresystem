#!/usr/bin/env bash
#
# iam_register_verify_onchain.sh
#
# End-to-end IAM provisioning for a batch of users:
#   1. Register account                 POST /api/v1/auth/register
#   2. Verify email (TEST_MODE token)   GET  /api/v1/auth/verify?token=verify_<email>
#   3. Login -> JWT                     POST /api/v1/auth/login
#   4. Link a real Solana wallet        POST /api/v1/users/me/wallets   (is_primary=true)
#   5. Register the user on-chain       POST /api/v1/users/me/onchain-profile
#   6. Read back the on-chain wallet    GET  /api/v1/users/me  +  /users/me/wallets
#
# Step 5 registers a user PDA via the Solana Registry program through Chain Bridge.
# It requires Chain Bridge up and a reachable Solana validator/RPC; if that is down
# the script reports the failure per-user and keeps going (does not abort the batch).
#
# Usage:
#   ./scripts/iam_register_verify_onchain.sh                # default 3-user batch
#   COUNT=10 ./scripts/iam_register_verify_onchain.sh       # generate 10 users
#   USERS_FILE=users.tsv ./scripts/iam_register_verify_onchain.sh
#       (TSV lines: username<TAB>email<TAB>password<TAB>user_type)
#   BASE=http://localhost:4010 ./scripts/iam_register_verify_onchain.sh
#
set -uo pipefail   # NOTE: no -e — one user failing must not kill the batch

# ── Config ──────────────────────────────────────────────────────────────────
BASE="${BASE:-http://localhost:4010}"
COUNT="${COUNT:-3}"
DEFAULT_PASS="${DEFAULT_PASS:-TestPass123!}"
# Bangkok-ish coordinates in E7 (lat * 1e7, long * 1e7)
LAT_E7="${LAT_E7:-13750000}"
LONG_E7="${LONG_E7:-100500000}"
TS=$(date +%s)
TMPDIR_KEYS=$(mktemp -d)

# Gateway headers required by the identity (wallet / on-chain) endpoints.
GW_HEADERS=(
  -H "x-gridtokenx-role: api-gateway"
  -H "x-gridtokenx-gateway-secret: ${GATEWAY_SECRET:-gridtokenx-gateway-secret-2025}"
)

# ── Deps ────────────────────────────────────────────────────────────────────
command -v jq   >/dev/null || { echo "FATAL: jq not found"; exit 1; }
command -v curl >/dev/null || { echo "FATAL: curl not found"; exit 1; }
HAVE_KEYGEN=1
command -v solana-keygen >/dev/null || HAVE_KEYGEN=0

cleanup() { rm -rf "$TMPDIR_KEYS"; }
trap cleanup EXIT

# ── Pretty print ────────────────────────────────────────────────────────────
c_blue=$'\033[1;34m'; c_grn=$'\033[1;32m'; c_red=$'\033[1;31m'
c_yel=$'\033[1;33m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
hr() { printf '%s\n' "${c_dim}────────────────────────────────────────────────────────────${c_rst}"; }
step() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$1"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$1"; }

# ── Health gate ─────────────────────────────────────────────────────────────
if ! curl -fsS -m 5 "$BASE/health" >/dev/null 2>&1; then
  echo "${c_red}FATAL:${c_rst} IAM service not reachable at $BASE/health"
  echo "Start it:  docker compose up -d iam-service"
  exit 1
fi

# ── Build the user list ─────────────────────────────────────────────────────
# Each entry: "username<TAB>email<TAB>password<TAB>user_type"
declare -a USERS=()
if [[ -n "${USERS_FILE:-}" ]]; then
  [[ -f "$USERS_FILE" ]] || { echo "FATAL: USERS_FILE '$USERS_FILE' not found"; exit 1; }
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    USERS+=("$line")
  done < "$USERS_FILE"
else
  # Alternate prosumer / consumer across the generated batch.
  for i in $(seq 1 "$COUNT"); do
    if (( i % 2 == 1 )); then utype="prosumer"; else utype="consumer"; fi
    uname="user_${utype}_${TS}_${i}"
    USERS+=("${uname}"$'\t'"${uname}@example.com"$'\t'"${DEFAULT_PASS}"$'\t'"${utype}")
  done
fi

echo "${c_blue}IAM register → verify → on-chain${c_rst}   base=$BASE   users=${#USERS[@]}"
if (( HAVE_KEYGEN == 0 )); then
  echo "${c_yel}WARN:${c_rst} solana-keygen not found — will use the mock wallet minted at"
  echo "      verify time. On-chain registration may be rejected for a non-real key."
fi
hr

# ── Result accumulators (for the final summary table) ───────────────────────
declare -a SUM_USER=() SUM_WALLET=() SUM_ONCHAIN=() SUM_SIG=()
N_OK=0; N_PARTIAL=0; N_FAIL=0

api() {  # api METHOD PATH [curl args...] -> body on stdout, http code on fd 3-less trick
  local method="$1" path="$2"; shift 2
  curl -s -X "$method" "$BASE$path" "$@"
}

provision_one() {
  local username="$1" email="$2" password="$3" utype="$4"
  printf '%s● %s%s  %s(%s)%s\n' "$c_blue" "$username" "$c_rst" "$c_dim" "$utype" "$c_rst"

  # 1. Register ───────────────────────────────────────────────────────────────
  local reg
  reg=$(api POST /api/v1/auth/register \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$password\"}")
  if echo "$reg" | jq -e '.id' >/dev/null 2>&1; then
    ok "registered  id=$(echo "$reg" | jq -r '.id')"
  elif echo "$reg" | grep -qi 'already\|conflict\|exists'; then
    step "already registered — continuing"
  else
    bad "register failed: $(echo "$reg" | head -c 200)"
    SUM_USER+=("$username"); SUM_WALLET+=("-"); SUM_ONCHAIN+=("REGISTER_FAIL"); SUM_SIG+=("-")
    ((N_FAIL++)); echo; return
  fi

  # 2. Verify email (TEST_MODE token: verify_<email>) ─────────────────────────
  local vr
  vr=$(api GET "/api/v1/auth/verify?token=verify_${email}")
  if echo "$vr" | jq -e '.success == true' >/dev/null 2>&1; then
    ok "email verified  mock_wallet=$(echo "$vr" | jq -r '.wallet_address // "-"')"
  else
    bad "verify failed: $(echo "$vr" | head -c 200)"
    SUM_USER+=("$username"); SUM_WALLET+=("-"); SUM_ONCHAIN+=("VERIFY_FAIL"); SUM_SIG+=("-")
    ((N_FAIL++)); echo; return
  fi

  # 3. Login → JWT ────────────────────────────────────────────────────────────
  local login token
  login=$(api POST /api/v1/auth/login \
          -H "Content-Type: application/json" \
          -d "{\"username\":\"$username\",\"password\":\"$password\"}")
  token=$(echo "$login" | jq -r '.access_token // empty')
  if [[ -z "$token" ]]; then
    bad "login failed: $(echo "$login" | head -c 200)"
    SUM_USER+=("$username"); SUM_WALLET+=("-"); SUM_ONCHAIN+=("LOGIN_FAIL"); SUM_SIG+=("-")
    ((N_FAIL++)); echo; return
  fi
  ok "logged in"
  local AUTH=(-H "Authorization: Bearer $token")

  # 4. Link a real Solana wallet as primary ───────────────────────────────────
  local wallet=""
  if (( HAVE_KEYGEN == 1 )); then
    local kf="$TMPDIR_KEYS/${username}.json"
    solana-keygen new --no-bip39-passphrase --silent --force --outfile "$kf" >/dev/null 2>&1
    wallet=$(solana-keygen pubkey "$kf" 2>/dev/null)
    local link
    link=$(api POST /api/v1/users/me/wallets \
           "${GW_HEADERS[@]}" "${AUTH[@]}" \
           -H "Content-Type: application/json" \
           -d "{\"wallet_address\":\"$wallet\",\"label\":\"Primary\",\"is_primary\":true}")
    if echo "$link" | jq -e '.id' >/dev/null 2>&1; then
      ok "linked real wallet  $wallet"
    else
      step "wallet link returned: $(echo "$link" | head -c 160)"
    fi
  else
    # No keygen: fall back to the mock wallet the verify step already set primary.
    wallet=$(echo "$vr" | jq -r '.wallet_address // "-"')
    step "using mock wallet  $wallet"
  fi

  # 5. Register on-chain (Registry PDA via Chain Bridge) ───────────────────────
  local onb status sig
  onb=$(api POST /api/v1/users/me/onchain-profile \
        "${GW_HEADERS[@]}" "${AUTH[@]}" \
        -H "Content-Type: application/json" \
        -d "{\"user_type\":\"$utype\",\"location\":{\"lat_e7\":$LAT_E7,\"long_e7\":$LONG_E7}}")
  status=$(echo "$onb" | jq -r '.status // "unknown"')
  sig=$(echo "$onb" | jq -r '.transaction_signature // "-"')

  # 6. Read back the wallet that on-chain registration used ────────────────────
  # The primary wallet in user_wallets is the one the Registry PDA is derived
  # from. Prefer it over users.wallet_address (which may still hold the legacy
  # mock address minted at verify time).
  local wl onchain_addr
  wl=$(api GET /api/v1/users/me/wallets "${GW_HEADERS[@]}" "${AUTH[@]}")
  onchain_addr=$(echo "$wl" | jq -r '.wallets[]? | select(.is_primary==true) | .wallet_address' | head -1)
  [[ -z "$onchain_addr" ]] && onchain_addr=$(api GET /api/v1/users/me "${GW_HEADERS[@]}" "${AUTH[@]}" | jq -r '.wallet_address // "-"')

  if [[ "$status" == "processing" || "$status" == "registered" || "$status" == "success" ]]; then
    ok "on-chain status=$status  sig=$sig"
    ok "on-chain wallet=$onchain_addr"
    SUM_ONCHAIN+=("$status"); ((N_OK++))
  else
    bad "on-chain status=$status  resp=$(echo "$onb" | head -c 200)"
    SUM_ONCHAIN+=("FAILED($status)"); ((N_PARTIAL++))
  fi
  SUM_USER+=("$username"); SUM_WALLET+=("$onchain_addr"); SUM_SIG+=("$sig")
  echo
}

# ── Run the batch ───────────────────────────────────────────────────────────
for entry in "${USERS[@]}"; do
  IFS=$'\t' read -r u e p t <<< "$entry"
  provision_one "$u" "$e" "$p" "${t:-consumer}"
done

# ── Summary ─────────────────────────────────────────────────────────────────
hr
echo "${c_blue}Summary${c_rst}   ok=$N_OK  on-chain-failed=$N_PARTIAL  hard-failed=$N_FAIL"
hr
printf '%-28s %-46s %-14s %s\n' "USER" "WALLET (on-chain)" "STATUS" "TX_SIG"
for i in "${!SUM_USER[@]}"; do
  printf '%-28s %-46s %-14s %s\n' \
    "${SUM_USER[$i]}" "${SUM_WALLET[$i]:--}" "${SUM_ONCHAIN[$i]}" "${SUM_SIG[$i]:--}"
done

# Exit non-zero only if a hard auth/registration failure occurred.
(( N_FAIL == 0 )) || exit 1
