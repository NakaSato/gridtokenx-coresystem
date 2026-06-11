#!/usr/bin/env bash
# Suite 50 (bash part) — Chain Bridge RBAC policy invariants via Rust test.
# The signing-authority isolation (which role may submit which program's tx) is
# enforced by PolicyEngine; the canonical coverage already lives in the service's
# own crates/chain-bridge-api/tests/invariants.rs. We wrap it so it runs as part of the e2e gate.
# Python read/auth cases live in test_chain_bridge.py (auto-run by orchestrator).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
CB="$ROOT/gridtokenx-chain-bridge"

log_info "Chain Bridge RBAC policy invariants (cargo test --test invariants)"
if [ ! -d "$CB" ] || [ ! -f "$CB/crates/chain-bridge-api/tests/invariants.rs" ]; then
    log_warn "invariants.rs not found — submodule not checked out? skipping"
    suite_summary
    exit 0
fi

if command -v cargo >/dev/null; then
    # Unset CHAIN_BRIDGE_INSECURE: env.sh sets it true so the *running* bridge grants Admin
    # to all callers (dev), but these invariants assert the SECURE role->program policy. If
    # the var leaks into the test it flips to Admin-everywhere and the negative cases
    # (service-cannot-submit-foreign-program / unknown-identity-rejected) falsely fail.
    if ( cd "$CB" && env -u CHAIN_BRIDGE_INSECURE cargo test -p chain-bridge-api --test invariants -- --nocapture ) ; then
        log_success "RBAC invariants passed (role->program submission policy enforced)"
    else
        log_fail "RBAC invariants failed"
    fi
else
    log_warn "cargo not present — skipping Rust invariants"
fi

# Bind note: code binds 0.0.0.0 (main.rs), with mTLS as the isolation boundary.
# CLAUDE.md states 127.0.0.1-only — DISCREPANCY flagged in E2E_IMPL_PLAN.md.

suite_summary
