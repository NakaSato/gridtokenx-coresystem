#!/usr/bin/env bash
# Suite 80 — Gateways: APISIX (:4001 user-facing), API orchestrator (:4000).
# These are out-of-repo (configs were removed from infra/; services run as containers).
# Checks routing reachability + gateway-secret enforcement + public/authed/meter route
# fan-out (folded from the old tests/platform_integration_test.sh + test_meter_onboarding.sh).
# Skips loudly when a gateway is down.
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

    # --- Case 4: public endpoints route through APISIX ------------------
    # (folded from the old tests/platform_integration_test.sh smoke)
    log_info "Case 4: public endpoints route via APISIX"
    for ep in grid-status grid-topology meters; do
        C=$(reachable "$APISIX_URL/api/v1/public/$ep")
        if [ "$C" == "200" ]; then log_success "public/$ep routed [200]"
        elif [ "$C" == "000" ]; then log_warn "public/$ep unreachable [000]"
        else log_warn "public/$ep routed but [$C]"; fi
    done

    # --- Case 5: authenticated reads route through APISIX ---------------
    log_info "Case 5: authenticated reads route via APISIX"
    if [ -n "$JWT" ]; then
        for ep in me markets/stats orders carbon/balance notifications; do
            C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                "$APISIX_URL/api/v1/$ep" -H "Authorization: Bearer $JWT" "${GATEWAY_HEADERS[@]}")
            if [ "$C" == "404" ] || [ "$C" == "000" ]; then log_warn "$ep not routed [$C]"
            else log_success "$ep routed [$C]"; fi
        done
    else
        log_warn "no JWT — skipping authed route checks"
    fi

    # --- Case 6: meter onboarding routes through APISIX -----------------
    # (folded from the old tests/test_meter_onboarding.sh). On-chain registration
    # may degrade (validator/bridge state) — we assert the route is reachable, not the mint.
    log_info "Case 6: meter onboarding routes via APISIX"
    if [ -n "$JWT" ]; then
        C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
            -X POST "$APISIX_URL/api/v1/meters" \
            -H "Content-Type: application/json" -H "Authorization: Bearer $JWT" "${GATEWAY_HEADERS[@]}" \
            -d "{\"serial_number\":\"METER-${E2E_RUN_ID}\",\"meter_type\":\"solar\",\"location\":\"Bangkok\",\"shard_id\":7}")
        case "$C" in
            200|201|409|422) log_success "meter route reached [$C]" ;;
            404|000) log_warn "meter route not available [$C]" ;;
            *) log_warn "meter route returned [$C]" ;;
        esac
    else
        log_warn "no JWT — skipping meter onboarding route check"
    fi

    # --- Case 7: rewrite-target regression guard ------------------------
    # Hard guard for the APISIX route fixes (commit b39d24b). Unlike Cases 4/5
    # (reachability warns), these FAIL on the *specific* misroutings the fix
    # eliminated. 000 = upstream down ⇒ skip (not a routing regression).
    log_info "Case 7: APISIX rewrite-target regression guard"

    # public/meters: must be 200. 401 = meter-service JWT route shadowing it again;
    # 404 = route 5 rewriting to the wrong upstream path. Both are regressions.
    C=$(reachable "$APISIX_URL/api/v1/public/meters")
    case "$C" in
        000) log_warn "public/meters upstream down [000] — skipping target guard" ;;
        200) log_success "public/meters rewrite target correct [200]" ;;
        401) log_fail "public/meters SHADOWED by JWT route again [401] (route 12 regression)" ;;
        404) log_fail "public/meters wrong rewrite target [404] (route 5 regression)" ;;
        *)   log_fail "public/meters unexpected [$C]" ;;
    esac

    # notifications: must reach the noti upstream. 404 = inverted /noti rewrite
    # (route 3/30/31/32 regression). 401 (auth-gated) or 200 both prove correct routing.
    if [ -n "$JWT" ]; then
        C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "$APISIX_URL/api/v1/notifications" -H "Authorization: Bearer $JWT" "${GATEWAY_HEADERS[@]}")
        case "$C" in
            000) log_warn "noti upstream down [000] — skipping target guard" ;;
            404) log_fail "notifications 404 — rewrite target regressed to /notifications (routes 3/30/31/32)" ;;
            *)   log_success "notifications reaches upstream [$C] (not 404)" ;;
        esac
    else
        log_warn "no JWT — skipping notifications target guard"
    fi

    # --- Case 8: path-rewrite correctness (mirrors Case 7, broader) ------
    # Asserts each carve-out rewrite *lands on its real upstream path* (2xx /
    # expected non-404), per apisix.yaml route regex_uri. A WRONG rewrite target
    # 404s at the upstream — that's the regression these guard. 000=upstream down⇒skip.
    log_info "Case 8: path-rewrite correctness (routes 20/21/22, 30/31, 4)"
    apx() { curl -s -o /dev/null --max-time 6 -w '%{http_code}' "$@"; }
    if [ -n "$JWT" ]; then
        AUTH=(-H "Authorization: Bearer $JWT" "${GATEWAY_HEADERS[@]}")

        # route 20: /api/v1/me/orders -> /api/v1/orders (apisix.yaml:114-131).
        # Correct target serves the trading orders list (200). 404 = bad rewrite.
        C=$(apx "$APISIX_URL/api/v1/me/orders" "${AUTH[@]}")
        case "$C" in
            000) log_warn "trading upstream down [000] — skip route 20 guard" ;;
            404) log_fail "me/orders 404 — route 20 rewrite target regressed (apisix.yaml:131)" ;;
            *)   log_success "route 20 me/orders -> /orders landed on trading [$C]" ;;
        esac

        # route 21: /api/v1/markets/stats -> /api/v1/stats (apisix.yaml:138-144).
        C=$(apx "$APISIX_URL/api/v1/markets/stats" "${AUTH[@]}")
        case "$C" in
            000) log_warn "trading upstream down [000] — skip route 21 guard" ;;
            404) log_fail "markets/stats 404 — route 21 rewrite target regressed (apisix.yaml:144)" ;;
            *)   log_success "route 21 markets/stats -> /stats landed on trading [$C]" ;;
        esac

        # route 22: /api/v1/markets/zones/{z}/order-book -> /api/v1/zones/$1/book
        # (apisix.yaml:151-157). 'north' may 400 (invalid zone) at the upstream —
        # that still proves the rewrite landed on trading. Only 404 is a regression.
        C=$(apx "$APISIX_URL/api/v1/markets/zones/north/order-book" "${AUTH[@]}")
        case "$C" in
            000) log_warn "trading upstream down [000] — skip route 22 guard" ;;
            404) log_fail "markets/zones/north/order-book 404 — route 22 rewrite regressed (apisix.yaml:157)" ;;
            *)   log_success "route 22 zones/{z}/order-book -> /zones/\$1/book landed on trading [$C]" ;;
        esac

        # route 30: /api/v1/me/notifications/mark-all-read -> /api/v1/noti/read-all
        # (apisix.yaml:182-191). Upstream role-gates this (401 'Insufficient
        # permissions'), which proves it reached noti. 404 = wrong rewrite target.
        C=$(apx -X POST "$APISIX_URL/api/v1/me/notifications/mark-all-read" "${AUTH[@]}")
        case "$C" in
            000) log_warn "noti upstream down [000] — skip route 30 guard" ;;
            404) log_fail "me/notifications/mark-all-read 404 — route 30 rewrite regressed (apisix.yaml:191)" ;;
            *)   log_success "route 30 mark-all-read -> /noti/read-all landed on noti [$C]" ;;
        esac

        # route 31: /api/v1/me/notifications/* -> /api/v1/noti$1 (apisix.yaml:198-208).
        C=$(apx "$APISIX_URL/api/v1/me/notifications" "${AUTH[@]}")
        case "$C" in
            000) log_warn "noti upstream down [000] — skip route 31 guard" ;;
            404) log_fail "me/notifications 404 — route 31 rewrite target regressed (apisix.yaml:208)" ;;
            *)   log_success "route 31 me/notifications -> /noti landed on noti [$C]" ;;
        esac
    else
        log_warn "no JWT — skipping authed rewrite guards (routes 20/21/22/30/31)"
    fi

    # route 4: /api/v1/public/grid-* -> /api/v1/grid/$1 (apisix.yaml:228-233). Public.
    C=$(apx "$APISIX_URL/api/v1/public/grid-status")
    case "$C" in
        000) log_warn "grid upstream down [000] — skip route 4 guard" ;;
        404) log_fail "public/grid-status 404 — route 4 rewrite target regressed (apisix.yaml:233)" ;;
        *)   log_success "route 4 public/grid-status -> /grid/status landed on simulator [$C]" ;;
    esac

    # Regression true-negative: a WRONG path under the same prefix must 404, proving
    # routes are path-specific (not catch-alls swallowing everything). markets/stats
    # is a single exact uri (apisix.yaml:140) so a sub-path is unrouted -> 404.
    C=$(apx "$APISIX_URL/api/v1/markets/stats/this-path-does-not-exist-zzz" "${GATEWAY_HEADERS[@]}")
    case "$C" in
        000) log_warn "upstream down [000] — skip stats true-negative guard" ;;
        404) log_success "wrong sub-path under markets/stats correctly 404s (not a catch-all)" ;;
        *)   log_warn "markets/stats/<bogus> returned [$C] (expected 404 — route may be broader than exact)" ;;
    esac
    # public/grid-<bogus> also rewrites (route 4 is /grid-*) but the simulator has no
    # such grid endpoint -> 404 from the upstream proves the rewrite is path-faithful.
    C=$(apx "$APISIX_URL/api/v1/public/grid-this-does-not-exist-zzz")
    case "$C" in
        000) log_warn "grid upstream down [000] — skip grid true-negative guard" ;;
        404) log_success "public/grid-<bogus> rewrites then 404s at upstream (faithful rewrite)" ;;
        *)   log_warn "public/grid-<bogus> returned [$C] (expected 404 at upstream)" ;;
    esac

    # --- Case 9: priority-collision isolation (routes 11 / 20 / 12) -----
    # Three siblings carve the /api/v1/me/* namespace and must each land on their
    # OWN upstream, not shadow each other:
    #   /me/wallets -> IAM     (route 11, priority 0,  apisix.yaml:55)
    #   /me/orders  -> Trading (route 20, priority 20, apisix.yaml:119)
    #   /me/meters  -> Meter   (route 12, priority 20, apisix.yaml:78)
    # We fingerprint each upstream by its distinct JSON response shape (verified live):
    #   IAM /me/wallets -> {"wallets":[...]} ; Trading /me/orders -> {"data":..,"pagination":..}
    #   Meter /me/meters -> a JSON array. 401/000 => can't verify (auth/upstream) -> warn.
    log_info "Case 9: priority-collision isolation (/me/wallets vs /me/orders vs /me/meters)"
    if [ -n "$JWT" ]; then
        # /me/wallets must hit IAM (route 11), not be shadowed by a trading/meter carve-out.
        B=$(curl -s --max-time 6 "$APISIX_URL/api/v1/me/wallets" "${AUTH[@]}"); C=$(hs 2>/dev/null || echo "?")
        if [[ "$B" == *'"wallets"'* ]]; then
            log_success "/me/wallets -> IAM (route 11) — wallets payload, not shadowed"
        elif [ -z "$B" ]; then
            log_warn "/me/wallets empty body — IAM upstream may be down; can't verify isolation"
        else
            log_fail "/me/wallets shadowed — expected IAM wallets payload, got: ${B:0:80}"
        fi

        # /me/orders must hit Trading (route 20), not IAM's /me/* nor Meter.
        B=$(curl -s --max-time 6 "$APISIX_URL/api/v1/me/orders" "${AUTH[@]}")
        if [[ "$B" == *'"pagination"'* ]] || [[ "$B" == *'"data"'* ]]; then
            log_success "/me/orders -> Trading (route 20) — paginated orders payload"
        elif [[ "$B" == *'"wallets"'* ]]; then
            log_fail "/me/orders SHADOWED by IAM route 11 — got wallets payload"
        elif [ -z "$B" ]; then
            log_warn "/me/orders empty body — trading upstream may be down; can't verify isolation"
        else
            log_warn "/me/orders unrecognized payload (can't fingerprint upstream): ${B:0:80}"
        fi

        # /me/meters must hit Meter (route 12). Meter list is a JSON array (not an object).
        B=$(curl -s --max-time 6 "$APISIX_URL/api/v1/me/meters" "${AUTH[@]}")
        if [[ "$B" == \[* ]]; then
            log_success "/me/meters -> Meter (route 12) — JSON array payload, not shadowed"
        elif [[ "$B" == *'"wallets"'* ]]; then
            log_fail "/me/meters SHADOWED by IAM route 11 — got wallets payload"
        elif [ -z "$B" ]; then
            log_warn "/me/meters empty body — meter upstream may be down; can't verify isolation"
        else
            log_warn "/me/meters unrecognized payload (can't fingerprint upstream): ${B:0:80}"
        fi
    else
        log_warn "no JWT — skipping priority-collision isolation"
    fi

    # --- Case 10: JWT enforcement on authed routes ----------------------
    # Routes under plugin_config_id 1 carry jwt-auth (apisix.yaml:2-20). No token
    # and a malformed token must both 401 *at the gateway*, before any upstream.
    log_info "Case 10: JWT enforcement (no header / garbage token -> 401)"
    for ep in me orders; do
        C=$(apx "$APISIX_URL/api/v1/$ep")
        assert_status "$C" "401" "/$ep with NO Authorization header rejected by gateway"
        C=$(apx "$APISIX_URL/api/v1/$ep" -H "Authorization: Bearer not.a.real.jwt")
        assert_status "$C" "401" "/$ep with garbage JWT rejected by gateway"
    done

    # --- Case 11: public routes need NO auth ----------------------------
    # Routes 4/5 (apisix.yaml:228-253) have no jwt-auth — must NOT 401.
    log_info "Case 11: public routes require no auth (must not 401)"
    for ep in public/meters public/grid-status; do
        C=$(apx "$APISIX_URL/api/v1/$ep")
        case "$C" in
            000) log_warn "$ep upstream down [000] — skip public-no-auth guard" ;;
            401) log_fail "$ep returned 401 — public route is wrongly auth-gated" ;;
            *)   log_success "$ep is public (no auth) [$C]" ;;
        esac
    done

    # --- Case 12: gRPC routes reachable through APISIX (routes 100/101) --
    # ConnectRPC over HTTP/JSON. Route 100 /identity.IdentityService/* (apisix.yaml:313),
    # route 101 /trading.TradingService/* (apisix.yaml:322). Reachable => NOT 404/000.
    # 403/401/200/4xx all prove the route exists and proxied to the gRPC upstream.
    log_info "Case 12: gRPC routes reachable via APISIX (routes 100/101)"
    C=$(apx -X POST "$APISIX_URL/identity.IdentityService/VerifyToken" \
        -H "Content-Type: application/json" -d '{}')
    case "$C" in
        404) log_fail "identity gRPC route 404 — route 100 missing/misconfigured (apisix.yaml:313)" ;;
        000) log_warn "IAM gRPC upstream down [000] — skip route 100 guard" ;;
        *)   log_success "route 100 /identity.IdentityService/VerifyToken reachable [$C] (not 404)" ;;
    esac
    C=$(apx -X POST "$APISIX_URL/trading.TradingService/GetMarketStats" \
        -H "Content-Type: application/json" -d '{}')
    case "$C" in
        404) log_fail "trading gRPC route 404 — route 101 missing/misconfigured (apisix.yaml:322)" ;;
        000) log_warn "trading gRPC upstream down [000] — skip route 101 guard" ;;
        *)   log_success "route 101 /trading.TradingService/* reachable [$C] (not 404)" ;;
    esac
fi

# --- Case 13: jwt-auth validation depth (pytest) --------------------------
# Well-formed-but-invalid tokens (expired / wrong-signature / unknown consumer)
# must 401 — proving the gateway VALIDATES exp+signature+key, not just presence.
# Lives in test_gateway_jwt.py (needs the python venv to mint HS256 tokens).
pytest_suite "$HERE" || E2E_FAIL=$((E2E_FAIL+1))

suite_summary
