#!/usr/bin/env bash
# Suite 92 — Frontend: gridtokenx-trading (Next.js) -> APISIX -> trading-service,
# the one true 3-hop path (browser -> gateway -> backend). Wraps the frontend's
# own Playwright suite (gridtokenx-trading/tests/e2e/*.spec.ts) so it runs as part
# of `just e2e` / tests/e2e/run.sh instead of only standalone `npm run test:e2e`.
#
# Playwright's webServer block (gridtokenx-trading/playwright.config.ts) spawns
# `npm run dev` itself (reuseExistingServer outside CI) and drives a real Chromium
# against it — this is NOT a curl-only check like 80_gateways, it's the actual UI.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"

FRONTEND_DIR="$(cd "$HERE/../../../gridtokenx-trading" && pwd)"

reachable() { curl -s -o /dev/null --max-time 3 -w '%{http_code}' "$1" 2>/dev/null; }

# --- Case 1: APISIX reachable (frontend's only backend dependency) ------
log_info "Case 1: APISIX reachable ($APISIX_URL) — frontend talks to nothing else directly"
CODE=$(reachable "$APISIX_URL/api/v1/system/config")
if [ "$CODE" == "000" ]; then
    log_warn "APISIX down at $APISIX_URL — skipping frontend e2e (browser flow needs the gateway up)"
    suite_summary
    exit 0
fi
log_success "APISIX reachable [$CODE]"

# --- Case 2: Playwright + browsers installed -----------------------------
log_info "Case 2: Playwright installed in $FRONTEND_DIR"
if [ ! -x "$FRONTEND_DIR/node_modules/.bin/playwright" ]; then
    log_warn "playwright not installed (run 'npm install' in gridtokenx-trading) — skipping"
    suite_summary
    exit 0
fi
log_success "playwright bin present"

# --- Case 3: full browser flow (register -> login -> DCA/order CRUD) -----
# NEXT_PUBLIC_API_BASE_URL override: point the spawned `npm run dev` at the same
# APISIX_URL this orchestrator already validated, instead of the .env default
# (apisix.gridtokenx-coresystem.orb.local), which needs OrbStack-local DNS.
# --workers=1: each spec is a full register->verify->login->CRUD flow against one
# shared dev server; the default parallel workers contend for it and intermittently
# blow timing budgets that hold fine in isolation (observed: dca.spec.ts flaked only
# when racing order.spec.ts). Serial here trades wall-clock for determinism; local
# `npm run test:e2e` is untouched and still runs parallel for fast iteration.
log_info "Case 3: Playwright suite against $APISIX_URL"
PW_LOG="$(mktemp)"
if (
    cd "$FRONTEND_DIR" &&
    NEXT_PUBLIC_API_BASE_URL="$APISIX_URL" npx playwright test --workers=1 --reporter=line
) 2>&1 | tee "$PW_LOG"; then
    log_success "frontend e2e suite passed"
elif grep -q "Executable doesn't exist" "$PW_LOG"; then
    log_warn "playwright browser binary not installed (run 'npx playwright install' in gridtokenx-trading) — skipping, not a regression"
else
    log_fail "frontend e2e suite failed — see $FRONTEND_DIR/playwright-report"
fi
rm -f "$PW_LOG"

suite_summary
