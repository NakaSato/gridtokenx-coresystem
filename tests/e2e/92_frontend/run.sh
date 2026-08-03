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
# --- Port isolation: never test a server this suite didn't start -----------
# Playwright's `reuseExistingServer` (outside CI) reuses ANY live server on the
# target port without checking what it serves. On 2026-08-03 that made all five
# register/login specs time out hunting a "Connect" button on a page that turned
# out to be a DIFFERENT project's dev server squatting :3000 (UTCC AI Academy) —
# the failure read as a broken trading UI when the UI was never under test at
# all. Run on a dedicated port, and if something already holds it, verify it is
# actually the trading UI (homepage title carries "GridTokenX",
# gridtokenx-trading/app/layout.tsx:19) before reusing — else fail loudly and
# name the squatter instead of testing a stranger's app.
FRONTEND_PORT="${FRONTEND_PORT:-3020}"
OCCUPANT="$(curl -s --max-time 3 "http://localhost:$FRONTEND_PORT" 2>/dev/null || true)"
# Bash pattern match, NOT `printf | grep -q`: under this script's `set -o
# pipefail`, grep -q exits at the first match and SIGPIPEs the still-writing
# printf (the page is ~180 KB), so the pipeline reports 141 and the guard
# refused the REAL trading UI as "foreign" — intermittently, since it races.
if [ -n "$OCCUPANT" ] && [[ "$OCCUPANT" != *GridTokenX* && "$OCCUPANT" != *gridtokenx* ]]; then
    TITLE="$(printf '%s' "$OCCUPANT" | grep -o '<title>[^<]*' | head -1 | cut -c8-60)"
    log_fail "port $FRONTEND_PORT is serving a foreign app (title: '${TITLE:-unknown}') — refusing to run the suite against it. Free the port or set FRONTEND_PORT."
    suite_summary
    exit 1
fi

# --- Pre-warm: compile every route BEFORE any test budget starts ------------
# Next dev compiles routes on first hit, and this app's trade page takes minutes
# to compile cold on a loaded machine — inside a 180s test budget that reads as
# five mysterious waitForTimeout timeouts (measured 2026-08-03: register→login
# passed and only the nav click failed once the server was warm). Start the dev
# server ourselves, curl each route under test until it compiles, THEN run
# playwright — reuseExistingServer picks ours up (the guard above already proved
# nothing foreign holds the port), so every test starts against warm routes.
DEV_LOG="$(mktemp)"
DEV_PID=""
if [ -z "$OCCUPANT" ]; then
    log_info "pre-warm: starting next dev on :$FRONTEND_PORT"
    ( cd "$FRONTEND_DIR" && PORT="$FRONTEND_PORT" NEXT_PUBLIC_API_BASE_URL="$APISIX_URL" npm run dev >"$DEV_LOG" 2>&1 ) &
    DEV_PID=$!
    for _ in $(seq 1 60); do
        curl -s -o /dev/null --max-time 2 "http://localhost:$FRONTEND_PORT" && break
        sleep 2
    done
fi
for route in / /portfolio /wallet /carbon-credit; do
    t0=$SECONDS
    code=$(curl -s -o /dev/null --max-time 240 -w '%{http_code}' "http://localhost:$FRONTEND_PORT$route" 2>/dev/null)
    log_info "pre-warm $route -> $code in $((SECONDS - t0))s"
done

log_info "Case 3: Playwright suite against $APISIX_URL (frontend on :$FRONTEND_PORT)"
PW_LOG="$(mktemp)"
if (
    cd "$FRONTEND_DIR" &&
    PORT="$FRONTEND_PORT" NEXT_PUBLIC_API_BASE_URL="$APISIX_URL" npx playwright test --workers=1 --reporter=line
) 2>&1 | tee "$PW_LOG"; then
    log_success "frontend e2e suite passed"
elif grep -q "Executable doesn't exist" "$PW_LOG"; then
    log_warn "playwright browser binary not installed (run 'npx playwright install' in gridtokenx-trading) — skipping, not a regression"
else
    log_fail "frontend e2e suite failed — see $FRONTEND_DIR/playwright-report"
fi
rm -f "$PW_LOG"

# Reap the pre-warm dev server we started (leave a pre-existing one alone).
if [ -n "${DEV_PID:-}" ]; then
    kill "$DEV_PID" 2>/dev/null
    pkill -f "next dev.*$FRONTEND_PORT" 2>/dev/null || true
fi
rm -f "$DEV_LOG"

suite_summary
