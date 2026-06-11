#!/usr/bin/env bash
# Suite 00 — harness smoke. Proves scaffold wiring + service reachability.
# No business assertions; just confirms the rig works before real suites run.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/db.sh"
source "$HERE/../lib/http.sh"

log_info "Smoke: env loaded, run id = $E2E_RUN_ID"

# 1. jq + curl present
command -v jq  >/dev/null && log_success "jq present"  || log_fail "jq missing"
command -v curl >/dev/null && log_success "curl present" || log_fail "curl missing"

# 2. IAM reachable (any HTTP response on register path = service up)
http_json POST "$IAM_URL/api/v1/auth/register" '{}' >/dev/null
if [ -n "${HTTP_STATUS:-}" ] && [ "$HTTP_STATUS" != "000" ]; then
    log_success "IAM reachable at $IAM_URL [$HTTP_STATUS]"
else
    log_fail "IAM unreachable at $IAM_URL"
fi

# 3. End-to-end helper smoke: register+verify a throwaway user
new_user >/dev/null 2>&1 || true; JWT="${E2E_JWT:-}"
assert_nonempty "$JWT" "register+verify yields JWT (new_user helper)"
assert_nonempty "${WALLET_ADDRESS:-}" "primary wallet linked (new_user helper)"

suite_summary
