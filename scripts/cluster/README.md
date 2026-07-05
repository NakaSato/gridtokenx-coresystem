# Multi-node PoA cluster benchmark (scaffold)

Stands up a local **N-node permissioned (PoA-style) Agave cluster** and measures
**cross-node consensus TPS + finality lag** — the experiment the paper's
`@sec:onchain-throughput` currently flags as future work (all existing benches run on a
single `solana-test-validator`).

> **Status: SCAFFOLD — written, not yet run.** Stand it up, sanity-check, then feed real
> numbers into `Paper/sections/evaluation-bench.typ`. Until then the paper keeps its
> single-node framing.

## Why this exists

The repo only had single-node tooling (`scripts/lib/common.sh:50`, `just solana-up`,
`surfpool`). "PoA" in the codebase = an on-chain `poa_config` PDA (application authority),
**not** validator consensus. Measuring the consensus cost that the paper assumes requires a
real multi-validator cluster — built here from scratch.

"PoA" = a **fixed, permissioned set of equally-staked voting validators** minted at genesis;
stock Agave consensus (leader rotation + Tower BFT) is unchanged.

## Prerequisites

- Agave/Solana toolchain on `PATH`: `solana-keygen`, `solana-genesis`, `agave-validator`
  (or `solana-validator`), `solana`.
- `@solana/web3.js` — resolved from `gridtokenx-anchor/node_modules` (run `npm i` there).
- macOS Apple Silicon: validators exhaust file descriptors fast. The script raises
  `ulimit -n 65536`, but **3 validators may still hit "too many open files"** — see
  CLAUDE.md macOS warning. Bump system limits if peers die on startup.

## Run

```bash
# 1. bring up a 3-node cluster (genesis with 3 equally-staked validators)
scripts/cluster/cluster-up.sh 3

# 2. verify all peers joined consensus
solana -u http://127.0.0.1:8899 validators     # expect 3 current validators
solana -u http://127.0.0.1:8899 gossip

# 3. benchmark consensus TPS + finality lag across nodes
scripts/cluster/cluster-tps.mjs http://127.0.0.1:8899 --nodes 3 \
    --conc 5,10,20,40 --tx 500 --csv cluster-tps-results.csv

# 4. tear down
scripts/cluster/cluster-down.sh          # add PURGE=1 to delete .cluster/
```

Ports: node `i` → RPC `8899+i`, gossip `8001+i*10`. Work dir: `.cluster/` (logs in
`.cluster/logs/node-*.log`).

## Output → paper

`cluster-tps-results.csv` columns:
`concurrency,tps,ok,fail,secs,goodput,maxSlotLag,reachableNodes`.

Once real:
1. Commit the CSV (mirror how TPC-C/OLTP CSVs are committed under `test-results/`).
2. In `Paper/sections/evaluation-bench.typ` (`@sec:onchain-throughput`): replace/augment the
   single-node ~0.5 TPS settle figures with the multi-node consensus TPS, add a
   **finality-lag** column, and lift the "single-validator" caveat.
3. In `Paper/sections/introduction.typ` / abstract / title: promote PoA back from
   design-assumption to a measured property (reverses review finding #1).
4. Re-run the doc-paper VERIFY mode to confirm the new numbers trace to the committed CSV.

## Limitations of this harness

- Transfers are a generic proxy (like BlockBench), not the energy settle path. For the
  settle-path consensus number, point a cluster-aware variant of
  `gridtokenx-anchor/tests/batch_settle_tps.ts` at the leader RPC instead.
- Equal stake = simplified PoA; it does not model weighted authority or Byzantine/deviant
  validators (the paper's other open item).
- Single TPS point per concurrency level — repeat ≥5× for CI, matching the ingest-ramp method.
