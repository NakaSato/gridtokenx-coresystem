#!/usr/bin/env bash
# cluster-up.sh — stand up a local N-node permissioned (PoA-style) Agave/Solana cluster
# for consensus-cost benchmarking. This is the multi-node counterpart to the single-node
# `solana-test-validator` launched by scripts/lib/common.sh:50.
#
# "PoA" here = a fixed, permissioned set of staked voting validators (genesis-minted stake,
# no new stake admitted at runtime). Stock Agave consensus (leader rotation + Tower BFT) is
# unchanged; the permissioning is that only these genesis identities hold vote stake.
#
# SCAFFOLD: written but NOT run. Verify binaries + macOS file limits before first use.
#
# Usage:
#   scripts/cluster/cluster-up.sh [N]      # N validators, default 3
#   NODES=3 KEEP=1 scripts/cluster/cluster-up.sh
#
# Then benchmark with: scripts/cluster/cluster-tps.mjs (points at the bootstrap RPC).
# Tear down with:      scripts/cluster/cluster-down.sh
set -euo pipefail

NODES="${1:-${NODES:-3}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${CLUSTER_DIR:-$ROOT/.cluster}"
LOGS="$WORK/logs"
BASE_RPC="${BASE_RPC:-8899}"      # node i RPC = BASE_RPC + i
BASE_GOSSIP="${BASE_GOSSIP:-8001}" # node i gossip = BASE_GOSSIP + i*10
BASE_FAUCET="${BASE_FAUCET:-9900}"
BOOTSTRAP_STAKE="${BOOTSTRAP_STAKE:-500000000000}"  # lamports of vote stake per node (equal weight = PoA)

# macOS Apple-Silicon: solana validators exhaust the default fd limit fast; 3 nodes need more.
# Mirrors the ulimit workaround the single-node app.sh path applies.
ulimit -n 65536 2>/dev/null || echo "WARN: could not raise ulimit -n (multi-node may hit 'too many open files')" >&2

need() { command -v "$1" >/dev/null 2>&1 || { echo "MISSING binary: $1 — install the Agave/Solana toolchain" >&2; exit 1; }; }
need solana-keygen
need solana-genesis
command -v agave-validator >/dev/null 2>&1 || command -v solana-validator >/dev/null 2>&1 || { echo "MISSING: agave-validator / solana-validator" >&2; exit 1; }
VALIDATOR_BIN="$(command -v agave-validator || command -v solana-validator)"
[ -n "$VALIDATOR_BIN" ] || { echo "MISSING: agave-validator / solana-validator" >&2; exit 1; }

echo "==> cluster: $NODES nodes, work dir $WORK"
rm -rf "$WORK"; mkdir -p "$WORK" "$LOGS"
cd "$WORK"

# --- 1. keypairs -----------------------------------------------------------
# faucet + per-node (identity, vote, stake). All silent, no passphrase.
kg() { solana-keygen new --no-bip39-passphrase -s -f -o "$1" >/dev/null; }
kg faucet.json
GENESIS_ARGS=()
for i in $(seq 0 $((NODES-1))); do
  kg "id-$i.json"; kg "vote-$i.json"; kg "stake-$i.json"
  # --bootstrap-validator triplet: identity vote stake (repeatable; mints equal stake = PoA)
  GENESIS_ARGS+=(--bootstrap-validator "$(solana-keygen pubkey id-$i.json)" \
                                       "$(solana-keygen pubkey vote-$i.json)" \
                                       "$(solana-keygen pubkey stake-$i.json)")
done

# --- 2. genesis ------------------------------------------------------------
# Single shared genesis containing all N staked voting validators.
solana-genesis \
  --ledger "$WORK/ledger" \
  --faucet-pubkey "$(solana-keygen pubkey faucet.json)" \
  --faucet-lamports 5000000000000000 \
  --bootstrap-validator-stake-lamports "$BOOTSTRAP_STAKE" \
  --bootstrap-validator-lamports 1000000000000 \
  --cluster-type development \
  --hashes-per-tick auto \
  "${GENESIS_ARGS[@]}" >/dev/null
echo "==> genesis built ($NODES staked validators, $BOOTSTRAP_STAKE lamports each)"

ENTRYPOINT="127.0.0.1:$BASE_GOSSIP"

launch() {
  local i="$1" rpc="$2" gossip="$3" extra="${4:-}"
  local ledger="$WORK/ledger-$i"
  # node 0 owns the genesis ledger; peers get a copy + fetch nothing from outside.
  if [ "$i" -eq 0 ]; then ledger="$WORK/ledger"; else cp -R "$WORK/ledger" "$ledger"; fi
  # shellcheck disable=SC2086
  "$VALIDATOR_BIN" \
    --identity "id-$i.json" \
    --vote-account "vote-$i.json" \
    --ledger "$ledger" \
    --rpc-port "$rpc" \
    --gossip-port "$gossip" \
    --dynamic-port-range "$((gossip+1))-$((gossip+20))" \
    --full-rpc-api --rpc-bind-address 127.0.0.1 \
    --enable-rpc-transaction-history \
    --no-genesis-fetch --no-snapshot-fetch \
    --no-os-network-limits-test \
    --allow-private-addr \
    --limit-ledger-size 50000000 \
    $extra \
    > "$LOGS/node-$i.log" 2>&1 &
  echo "$!" > "$WORK/node-$i.pid"
  echo "   node $i  rpc=$rpc gossip=$gossip pid=$(cat "$WORK/node-$i.pid")  log=$LOGS/node-$i.log"
}

# --- 3. launch bootstrap (node 0), then peers ------------------------------
echo "==> launching nodes"
launch 0 "$BASE_RPC" "$BASE_GOSSIP" "--rpc-faucet-address 127.0.0.1:$BASE_FAUCET"
for i in $(seq 1 $((NODES-1))); do
  launch "$i" "$((BASE_RPC+i))" "$((BASE_GOSSIP+i*10))" "--entrypoint $ENTRYPOINT --known-validator $(solana-keygen pubkey id-0.json)"
done

cat <<EOF

==> cluster up. Bootstrap RPC: http://127.0.0.1:$BASE_RPC
    Check health:  solana -u http://127.0.0.1:$BASE_RPC gossip
                   solana -u http://127.0.0.1:$BASE_RPC validators
    Benchmark:     scripts/cluster/cluster-tps.mjs http://127.0.0.1:$BASE_RPC
    Tear down:     scripts/cluster/cluster-down.sh

NOTE (scaffold): if peers don't appear in \`gossip\`/\`validators\`, the usual culprits are
genesis ledger copy timing, gossip port conflicts, or macOS fd limits. Inspect $LOGS/node-*.log.
EOF
