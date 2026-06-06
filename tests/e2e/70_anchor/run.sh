#!/usr/bin/env bash
# Suite 70 — Anchor on-chain programs. Runs the registry sharding program test
# (register_user / register_meter PDAs + 16-shard aggregation) against the LIVE
# app.sh validator, where the registry is already bootstrapped.
#
# HEAVY: needs the Solana toolchain + a running validator. Gate with
# E2E_RUN_ANCHOR=1 to opt in, since it is slow and toolchain-heavy.
#
# Two gotchas this wrapper works around (see docs/E2E_IMPL_PLAN.md):
#   1. `anchor test <file>` (anchor 1.0) IGNORES the file arg and runs the
#      Anchor.toml [scripts.test] glob `mocha 'tests/**/*.ts'`. That glob pulls
#      in tests/blockbench.ts, which imports a `blockbench` program IDL absent
#      from this workspace (only 5 programs) -> the whole run aborts before the
#      registry test executes. So we invoke mocha directly on the single file.
#   2. registry aggregate_shards requires caller == registry.authority, and the
#      live registry was bootstrapped by app.sh with the dev wallet
#      (EzudwoHv...) as authority. So ANCHOR_WALLET must be that dev wallet, and
#      both it and the register_user payer (~/.config/solana/id.json, hardcoded
#      in the test) must be funded.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
ANCHOR="$ROOT/gridtokenx-anchor"

echo "=== Anchor Suite | run $E2E_RUN_ID ==="

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

for bin in npx node solana solana-keygen; do
    if ! command -v "$bin" >/dev/null; then
        log_warn "$bin not on PATH — skipping (Solana/Node toolchain required)"
        suite_summary; exit 0
    fi
done

RPC="${SOLANA_RPC_URL:-http://localhost:8899}"
DEV_WALLET="${DEV_WALLET:-$ROOT/dev-wallet.json}"
ID_WALLET="$HOME/.config/solana/id.json"

# The live registry's authority is the dev wallet — without it aggregate_shards
# rejects with UnauthorizedAuthority, so this suite can't be satisfied.
if [ ! -f "$DEV_WALLET" ]; then
    log_warn "dev wallet $DEV_WALLET absent (registry authority) — skipping; run app.sh init first"
    suite_summary; exit 0
fi

# Validator must be up (this suite reads/writes on-chain state).
if ! solana cluster-version --url "$RPC" >/dev/null 2>&1; then
    log_warn "Solana validator unreachable at $RPC — skipping; run app.sh start first"
    suite_summary; exit 0
fi

# Fund both signers: dev wallet (provider/authority + funding source) and the
# test's hardcoded register_user payer ~/.config/solana/id.json. Idempotent;
# tolerate failure (e.g. faucet rate-limit) — the test fails loudly if underfunded.
DEV_PUB=$(solana-keygen pubkey "$DEV_WALLET" 2>/dev/null || true)
[ -n "$DEV_PUB" ] && solana airdrop 100 "$DEV_PUB" --url "$RPC" >/dev/null 2>&1 || true
if [ -f "$ID_WALLET" ]; then
    ID_PUB=$(solana-keygen pubkey "$ID_WALLET" 2>/dev/null || true)
    [ -n "$ID_PUB" ] && solana airdrop 100 "$ID_PUB" --url "$RPC" >/dev/null 2>&1 || true
fi

# Run ONLY the registry test directly via mocha (bypassing the broken glob).
TEST_FILE="${ANCHOR_TEST_FILE:-tests/registry_sharding.ts}"
log_info "Running anchor program test ($TEST_FILE) against $RPC"
OUT="${TMPDIR:-/tmp}/e2e-anchor-${E2E_RUN_ID}.log"
( cd "$ANCHOR" && ANCHOR_PROVIDER_URL="$RPC" ANCHOR_WALLET="$DEV_WALLET" \
    npx mocha -r tsx "$TEST_FILE" --timeout 1000000 ) >"$OUT" 2>&1
RC=$?

# Mocha prints "N passing" / "M failing"; treat any failing (or zero passing) as red.
PASSING=$(grep -oE '[0-9]+ passing' "$OUT" | grep -oE '[0-9]+' | head -1)
FAILING=$(grep -oE '[0-9]+ failing' "$OUT" | grep -oE '[0-9]+' | head -1)
PASSING="${PASSING:-0}"; FAILING="${FAILING:-0}"

if [ "$RC" -eq 0 ] && [ "$FAILING" -eq 0 ] && [ "$PASSING" -gt 0 ]; then
    log_success "anchor registry test passed ($PASSING passing, 0 failing)"
else
    log_fail "anchor registry test failed (rc=$RC, $PASSING passing, $FAILING failing) — see $OUT"
    grep -vE 'deprecated|references a signature' "$OUT" | tail -25
fi

suite_summary
