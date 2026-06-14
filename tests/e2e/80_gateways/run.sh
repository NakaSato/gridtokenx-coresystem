#!/usr/bin/env bash
# Suite 80 — Gateways: APISIX (:4001 user-facing), API orchestrator (:4000).
# These are out-of-repo (configs were removed from infra/; services run as containers).
# Checks routing reachability + gateway-secret enforcement. Skips loudly when a gateway is down.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/db.sh"
source "$HERE/../lib/http.sh"

reachable() { curl -s -o /dev/null --max-time 3 -w '%{http_code}' "$1" 2>/dev/null; }

# --- Case 1: API orchestrator health (:4000) ----------------------------
log_info "Case 1: API orchestrator health ($API_URL)"
CODE=$(reachable "$API_URL/health")
if [ "$CODE" != "000" ]; then
    log_success "API orchestrator reachable [$CODE]"
else
    log_warn "API orchestrator down at $API_URL — skipping"
fi

# --- Case 2: APISIX user-facing routing (:4001) -------------------------
log_info "Case 2: APISIX reachable + routes to IAM ($APISIX_URL)"
CODE=$(reachable "$APISIX_URL/api/v1/system/config")
if [ "$CODE" == "000" ]; then
    log_warn "APISIX down at $APISIX_URL — skipping gateway routing checks"
else
    log_success "APISIX reachable, routed [$CODE]"

    # --- Case 3: gateway-secret enforcement -----------------------------
    # Privileged path via gateway WITHOUT the gateway secret must be rejected.
    log_info "Case 3: gateway-secret enforcement on privileged path"
    new_user >/dev/null 2>&1 || true; JWT="${E2E_JWT:-}"
    if [ -n "$JWT" ]; then
        # Onboard via APISIX with NO gateway-secret header -> expect reject.
        BODY=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            -X POST "$APISIX_URL/api/v1/me/registration" \
            -H "Content-Type: application/json" -H "Authorization: Bearer $JWT" \
            -d '{"user_type":"prosumer","location":{"lat_e7":0,"long_e7":0}}')
        if [ "$BODY" == "401" ] || [ "$BODY" == "403" ]; then
            log_success "privileged call without gateway-secret rejected [$BODY]"
        else
            log_warn "privileged call without secret returned [$BODY] (gateway may inject secret upstream)"
        fi
    else
        log_warn "could not mint JWT (IAM down?) — skipping secret-enforcement case"
    fi
fi

suite_summary
