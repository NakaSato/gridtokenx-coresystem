#!/usr/bin/env node
// cluster-tps.mjs — cross-node consensus TPS + finality-lag probe for the local
// multi-node cluster (cluster-up.sh). This is the multi-node harness the repo lacks:
// existing benches (gridtokenx-anchor/tests/{tpc_stress_test,batch_settle_tps}.ts)
// all point at ONE RPC and measure single-node block production, not consensus.
//
// What it measures:
//   - settled TPS: signed transfer txs fired open-loop at a concurrency level,
//     counted by confirmations/sec at the bootstrap (leader) RPC.
//   - finality lag: slot distance between each peer RPC and the leader (consensus health).
//
// SCAFFOLD: not run. Needs @solana/web3.js (resolved from gridtokenx-anchor/node_modules)
// and a running cluster.
//
// Usage:
//   scripts/cluster/cluster-tps.mjs [leaderRpc] [--nodes 3] [--conc 5,10,20,40] [--tx 500] [--csv out.csv]
//
// Feed the CSV back into the paper: replace the single-node ~0.5 TPS / proxy numbers in
// Paper/sections/evaluation-bench.typ with the multi-node consensus figures + finality lag,
// and lift the "single-validator" caveat (#1 / @sec:onchain-throughput).

import { createRequire } from 'node:module';
import { writeFileSync } from 'node:fs';
const require = createRequire(import.meta.url);

// resolve web3.js from the anchor submodule's deps (kept out of this repo's package set)
let web3;
for (const p of ['@solana/web3.js', '../../gridtokenx-anchor/node_modules/@solana/web3.js']) {
  try { web3 = require(p); break; } catch { /* try next */ }
}
if (!web3) { console.error('MISSING @solana/web3.js — run `npm i` in gridtokenx-anchor first'); process.exit(1); }
const { Connection, Keypair, SystemProgram, Transaction, LAMPORTS_PER_SOL } = web3;

// --- args ------------------------------------------------------------------
const argv = process.argv.slice(2);
const leaderRpc = argv.find(a => a.startsWith('http')) || 'http://127.0.0.1:8899';
const opt = (name, def) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : def; };
const NODES = parseInt(opt('--nodes', '3'), 10);
const CONC = opt('--conc', '5,10,20,40').split(',').map(Number);
const TX = parseInt(opt('--tx', '500'), 10);
const CSV = opt('--csv', '');
const baseRpcPort = new URL(leaderRpc).port ? parseInt(new URL(leaderRpc).port, 10) : 8899;

const sleep = ms => new Promise(r => setTimeout(r, ms));
const leader = new Connection(leaderRpc, 'confirmed');
const peers = Array.from({ length: NODES }, (_, i) =>
  new Connection(`http://127.0.0.1:${baseRpcPort + i}`, 'confirmed'));

// --- finality lag: peer slot vs leader slot --------------------------------
async function finalityLag() {
  const slots = await Promise.allSettled(peers.map(c => c.getSlot('confirmed')));
  const vals = slots.map(s => (s.status === 'fulfilled' ? s.value : null));
  const live = vals.filter(v => v != null);
  const max = Math.max(...live);
  return { slots: vals, maxLag: live.length ? max - Math.min(...live) : null, reachable: live.length };
}

// --- one TPS point at a concurrency level ----------------------------------
async function tpsAt(conc, payer, dest) {
  // pre-sign TX transfers, then fire `conc` in flight, refilling as they confirm (open-loop).
  const { blockhash } = await leader.getLatestBlockhash('confirmed');
  let sent = 0, ok = 0, fail = 0, inFlight = 0;
  const t0 = Date.now();
  await new Promise(resolve => {
    const pump = () => {
      while (inFlight < conc && sent < TX) {
        sent++; inFlight++;
        const tx = new Transaction({ recentBlockhash: blockhash, feePayer: payer.publicKey })
          .add(SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: dest, lamports: 1 }));
        tx.sign(payer);
        leader.sendRawTransaction(tx.serialize(), { skipPreflight: true })
          .then(sig => leader.confirmTransaction(sig, 'confirmed'))
          .then(() => { ok++; })
          .catch(() => { fail++; })
          .finally(() => { inFlight--; (sent < TX || inFlight > 0) ? pump() : resolve(); });
      }
      if (sent >= TX && inFlight === 0) resolve();
    };
    pump();
  });
  const secs = (Date.now() - t0) / 1000;
  const lag = await finalityLag();
  return { conc, tps: +(ok / secs).toFixed(2), ok, fail, secs: +secs.toFixed(1),
           goodput: +(ok / (ok + fail || 1)).toFixed(4), maxLag: lag.maxLag, reachable: lag.reachable };
}

async function main() {
  console.error(`leader=${leaderRpc} nodes=${NODES} tx=${TX} conc=[${CONC}]`);
  const health = await finalityLag();
  console.error(`cluster reachable nodes: ${health.reachable}/${NODES}  maxSlotLag=${health.maxLag}`);
  if (health.reachable < NODES) console.error('WARN: not all peers reachable — start cluster / check logs');

  const payer = Keypair.generate();
  const dest = Keypair.generate().publicKey;
  console.error('airdropping payer…');
  await leader.confirmTransaction(await leader.requestAirdrop(payer.publicKey, 10 * LAMPORTS_PER_SOL), 'confirmed');

  const rows = [];
  for (const c of CONC) { const r = await tpsAt(c, payer, dest); rows.push(r); console.error(JSON.stringify(r)); await sleep(500); }

  const header = 'concurrency,tps,ok,fail,secs,goodput,maxSlotLag,reachableNodes';
  const lines = rows.map(r => [r.conc, r.tps, r.ok, r.fail, r.secs, r.goodput, r.maxLag, r.reachable].join(','));
  const out = [header, ...lines].join('\n');
  if (CSV) { writeFileSync(CSV, out + '\n'); console.error(`wrote ${CSV}`); } else { console.log(out); }
}
main().catch(e => { console.error(e); process.exit(1); });
