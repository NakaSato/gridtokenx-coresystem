#!/usr/bin/env bash
# Suite 70 — Anchor on-chain programs. Wraps the existing TS program tests.
# Covers registry (register_user / register_meter PDAs), oracle, governance, settlement.
# HEAVY: builds programs + spins a validator. Gate with E2E_RUN_ANCHOR=1 to opt in,
# since `anchor test` is slow and needs the Solana toolchain.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
ANCHOR="$ROOT/gridtokenx-anchor"

if [ "${E2E_RUN_ANCHOR:-0}" != "1" ]; then
    log_warn "Anchor suite skipped (set E2E_RUN_ANCHOR=1 to run — slow, needs Solana toolchain)"
    suite_summary; exit 0
fi

if [ ! -d "$ANCHOR" ] || [ ! -f "$ANCHOR/Anchor.toml" ]; then
    log_warn "gridtokenx-anchor not checked out — skipping"
    suite_summary; exit 0
fi

# macOS Apple Silicon: validator needs the raised fd limit (CLAUDE.md caveat).
ulimit -n 65536 2>/dev/null || true

if ! command -v anchor >/dev/null; then
    log_warn "anchor CLI not installed — skipping"
    suite_summary; exit 0
fi

# Registry test is the e2e-critical one (register_user/register_meter discriminators).
TEST_TARGET="${ANCHOR_TEST:-tests/registry_sharding.ts}"
log_info "Running anchor test ($TEST_TARGET)"
if ( cd "$ANCHOR" && anchor test "$TEST_TARGET" ); then
    log_success "anchor program tests passed ($TEST_TARGET)"
else
    log_fail "anchor program tests failed ($TEST_TARGET)"
fi

suite_summary
