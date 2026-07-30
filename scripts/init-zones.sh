#!/usr/bin/env bash
# Initialize trading ZoneMarket PDAs on the running validator (idempotent).
#
# A zone with no ZoneMarket account cannot settle: record_order_custodial takes
# zone_market as an AccountLoader, so an uninitialized zone fails on-chain order
# placement with AccountOwnedByWrongProgram (Custom 3007) — while the REST API
# still returns 200 and the CDA still matches the order off-chain. The order ends
# up `filled` with a NULL order_pda and a permanently_failed settlement.
#
# Usage:
#   ./scripts/init-zones.sh            # zones 0-9 + MEA/PEA codes 7583-7588
#   ZONES=4,5,6 ./scripts/init-zones.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANCHOR_DIR="${ANCHOR_DIR:-$PROJECT_ROOT/gridtokenx-anchor}"
RPC_URL="${RPC_URL:-http://localhost:8899}"
DEV_WALLET="${DEV_WALLET:-$PROJECT_ROOT/dev-wallet.json}"

[ -f "$DEV_WALLET" ] || { echo "✘ dev wallet not found: $DEV_WALLET (set DEV_WALLET)" >&2; exit 1; }
curl -s -m 5 -X POST "$RPC_URL" -H 'Content-Type: application/json' \
     -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' >/dev/null 2>&1 \
     || { echo "✘ Solana RPC not reachable at $RPC_URL" >&2; exit 1; }

cd "$ANCHOR_DIR"
ANCHOR_PROVIDER_URL="$RPC_URL" ANCHOR_WALLET="$DEV_WALLET" \
    npx tsx scripts/init-zone-markets.ts
