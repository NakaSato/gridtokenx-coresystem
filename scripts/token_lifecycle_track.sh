#!/usr/bin/env bash
# Track the GRID (energy-token) supply + per-transaction token movements across
# the three token lifecycle operations:
#   MINT   — aggregator surplus generation mint (chain.tx.mint -> MintGeneration): supply UP
#   SETTLE — trading ExecuteAtomicSettlement (atomic swap): supply NEUTRAL (transfer only)
#   BURN   — retire_energy_tokens == token_interface::burn (owner-signed): supply DOWN
#
# There is no live service trigger for BURN (chain-bridge NATS subjects are
# submit/cancel/mint/mintbatch/status — no burn), so this script's `burn`
# subcommand invokes the Token-2022 burn the retire instruction wraps, signed by
# the token-account owner, to demonstrate the supply-down leg.
#
# Subcommands:
#   supply                  print GRID mint total supply
#   delta <tx_sig>          decode a tx's pre/post token balances (per mint+owner)
#   balance <owner_pubkey>  print an owner's GRID token balance
#   burn <ata> <amount> <owner_keypair>   burn <amount> GRID from <ata> (owner signs)
#
# NOTE on supply readings: the smartmeter-simulator streams real telemetry for
# claimed meters, so ORGANIC surplus mints fire continuously in the background.
# That masks per-op deltas at the total-supply level — always read a single op's
# effect from its own `delta <sig>` (tx pre/post balances), not the supply counter.
#
# Env:
#   RPC        Solana RPC URL      (default http://127.0.0.1:8899)
#   GRID_MINT  energy-token mint   (default GktSLt9dFsTrSSxikMEQRNeQXhpN9NxUn4m9teixctVS)
#   TOKEN_PROGRAM  Token-2022 id   (default TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb)
set -uo pipefail

RPC="${RPC:-http://127.0.0.1:8899}"
GRID_MINT="${GRID_MINT:-GktSLt9dFsTrSSxikMEQRNeQXhpN9NxUn4m9teixctVS}"
TOKEN_PROGRAM="${TOKEN_PROGRAM:-TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb}"

rpc() { curl -s "$RPC" -X POST -H 'Content-Type: application/json' -d "$1"; }

supply() {
  rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenSupply\",\"params\":[\"$GRID_MINT\"]}" \
    | python3 -c 'import sys,json;v=json.load(sys.stdin)["result"]["value"];print(v["uiAmountString"],"GRID (decimals",str(v["decimals"])+")")'
}

balance() {
  rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountsByOwner\",\"params\":[\"$1\",{\"mint\":\"$GRID_MINT\"},{\"encoding\":\"jsonParsed\"}]}" \
    | python3 -c 'import sys,json;a=json.load(sys.stdin)["result"]["value"];print("no ATA" if not a else a[0]["account"]["data"]["parsed"]["info"]["tokenAmount"]["uiAmountString"]+" GRID @ "+a[0]["pubkey"])'
}

delta() {
  rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTransaction\",\"params\":[\"$1\",{\"encoding\":\"jsonParsed\",\"maxSupportedTransactionVersion\":0,\"commitment\":\"confirmed\"}]}" \
    | python3 -c '
import sys, json
r = json.load(sys.stdin).get("result")
if not r:
    print("tx not found (pruned by --limit-ledger-size, or not yet confirmed)"); sys.exit(0)
m = r["meta"]
print("tx err:", m["err"], "slot", r["slot"])
def idx(b):
    return {(x["mint"], x.get("owner","?")): x["uiTokenAmount"]["uiAmountString"] for x in (b or [])}
pre, post = idx(m.get("preTokenBalances")), idx(m.get("postTokenBalances"))
print("%-10s %-10s %14s %14s %12s" % ("mint","owner","pre","post","delta"))
for k in sorted(set(pre)|set(post)):
    a=float(pre.get(k) or 0); b=float(post.get(k) or 0)
    print("%-10s %-10s %14.4f %14.4f %+12.4f" % (k[0][:8], k[1][:8], a, b, b-a))
'
}

burn() {
  local ata="$1" amt="$2" owner="$3"
  command -v spl-token >/dev/null || { echo "spl-token cli required"; exit 1; }
  echo "supply before: $(supply)"
  spl-token burn "$ata" "$amt" --owner "$owner" --fee-payer "$owner" \
    --program-id "$TOKEN_PROGRAM" --url "$RPC"
  echo "supply after:  $(supply)  (net of any concurrent organic mints)"
}

case "${1:-}" in
  supply)  supply ;;
  balance) balance "$2" ;;
  delta)   delta "$2" ;;
  burn)    burn "$2" "$3" "$4" ;;
  *) echo "usage: $0 {supply | balance <owner> | delta <tx_sig> | burn <ata> <amount> <owner_keypair>}"; exit 2 ;;
esac
