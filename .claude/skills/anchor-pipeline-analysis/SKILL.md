---
name: Anchor Pipeline Analysis
description: Analyze the gridtokenx-anchor on-chain data pipeline — trace data flow from simulator dataset to blockchain, compute exact byte layouts of serialized structs / signed messages / instructions, size a transaction against the 1,232-byte packet MTU and the 200k/1.4M compute-unit budgets, and map the network hops (off-chain services → Chain Bridge → validator). Four modes: (1) PIPELINE trace a data path end-to-end with per-hop shape changes, (2) BYTES compute a Borsh/wire byte layout for a struct/message/account, (3) PACKET budget a transaction's serialized size + CU cost and find the binding limit, (4) HOPS map the network path a payload takes and the trust boundary crossed. Use when the user says "anchor-pipeline", "analyze the data pipeline", "byte layout", "packet size", "why does the batch cap", "transaction size budget", "network hops", "map the data flow to the blockchain", or wants the on-chain wire/size/path facts grounded in real gridtokenx-anchor code.
---

## Anchor Pipeline Analysis

Grounds every wire/size/hop claim about `gridtokenx-anchor` (the Solana Anchor
programs: registry, trading, oracle, energy-token, governance, treasury) and its
feeder pipeline (`gridtokenx-smartmeter-simulator` → bench replayers) in real
`path:line`. Numbers are **computed from the code**, never guessed. This is the
skill behind the paper's §4.7 / §4.8 / §5.5 / §5.8 claims.

Four modes. Pick from the user's phrasing; if unclear, ask which one.

---

### Inputs

- **Target** = the instruction / struct / script the user names (e.g.
  `settle_offchain_match`, `BatchMatchPair`, `bench-community-month.ts`,
  `export_bench_dataset.py`). If omitted, infer from the topic.
- **Repo layout**: on-chain code = `gridtokenx-anchor/programs/<prog>/src/`;
  replayers = `gridtokenx-anchor/scripts/*.ts`; dataset exporter =
  `gridtokenx-smartmeter-simulator/backend/experiments/`. All are their own git
  repos / workspaces.
- **Graph first**: use the `code-review-graph` MCP (`semantic_search_nodes`,
  `query_graph`, `get_impact_radius`) BEFORE Grep/Read. Fall back to `rg` (never
  `grep`) only if the graph misses. Cite `path:line` for every fact.

> **RTK caveat**: `rg` output through the token proxy sometimes rewrites long
> identifiers to `n`. If a match looks stubbed (e.g. `verify_n_signature`,
> `msg.extend...&self.n`), open the real file with Read to recover true names
> before quoting them.

---

### Reference constants (verify against code — don't trust from memory)

| constant | value | where / note |
| --- | --- | --- |
| Transaction packet MTU | **1,232 bytes** | Solana hard cap on the whole serialized tx |
| Default compute budget / ix | **200,000 CU** | `ComputeBudgetProgram.setComputeUnitLimit` if unset |
| Max compute / tx | **1,400,000 CU** | bench clamps to this: `scripts/bench-community-month.ts:276` |
| Signature (tx-level) | 64 bytes each | 1 fee-payer sig minimum |
| Blockhash + msg header | ~40–80 bytes | recent_blockhash(32) + header + account count varints |
| Ed25519 precompile ix DATA | `2 + 14 + 64 + 32 + msg_len` | header + offsets + sig + pubkey + message |
| Anchor account discriminator | 8 bytes | prepended to every `#[account]` data |
| Slot time (design target) | ~400 ms | platform target, not a measured value |
| Market clearing window | 900 s (15 min) | oracle `epoch_timestamp % 900 == 0` |
| Shards | 16 | registry `key[0] % 16`; treasury `shard_id < 16` |

**Borsh sizing rules** (Anchor's serializer — no padding, little-endian):
- Fixed scalar: `u8`=1, `u16`=2, `u32`=4, `u64`=8, `i64`=8, `bool`=1, `Pubkey`=32.
- `[u8; N]` = `N`. `[T; N]` = `N * sizeof(T)`.
- `Vec<T>` = `4` (len prefix) `+ Σ sizeof(elem)`.
- `Option<T>` = `1` (tag) `+ (sizeof(T) if Some else 0)`.
- `String` = `4` (len prefix) `+ utf8_bytes`.
- Struct = Σ fields, in declaration order, no alignment padding.

**ALT (Address Lookup Table)** compresses **account keys only** (32-byte pubkey →
1-byte table index in a v0 message). It does **NOT** compress instruction data —
signed messages, serialized payloads, and precompile sig blobs are unaffected.

---

### Mode 1 — PIPELINE (trace a data path end-to-end)

Goal: show how a payload changes shape at each hop from source to on-chain state.

1. **Anchor the endpoints.** Source (dataset file / meter reading / order) and sink
   (which program + account/PDA it lands in).
2. **Walk each hop**, recording the data shape and the `path:line` that transforms
   it. Canonical dataset→chain path:
   - `readings.jsonl` `{m,t,g,c}` (integer Wh) — `export_bench_dataset.py`
   - JS parse + client-side anomaly gate + surplus accumulation — replayer
   - `oracle.submit_meter_reading(chain_id, g, c, t, zone)` → `MeterState` PDA
   - registry sync (`update_meter_reading`) bounds totals by oracle
   - `energy-token` mint → `trading.deposit_escrow` → `settle_offchain_match`
     (atomic DvP) → withdraw + burn → `governance.issue_erc`
3. **Name the invariant** each hop enforces (gate filter, oracle-bounded mint,
   cap, nullifier, conservation Σ). Conservation chain: metered ≥ minted (accepted,
   capped) → settled → burned; withheld → REC; GRID + REC ≤ generation.
4. **Output**: a per-hop table (shape · program/account · path:line · invariant)
   plus a compact ASCII flow diagram.

---

### Mode 2 — BYTES (compute a byte layout)

Goal: an exact, field-by-field byte table for a struct, signed message, or account.

1. Read the struct / `get_message()` / account definition; list fields in order.
2. Apply the Borsh rules above; for Anchor accounts add the 8-byte discriminator.
3. Emit a table: `offset | field | bytes | encoding`, then the total.
4. Flag **duplication**: e.g. the 77-byte order message is stored twice per side in
   the batch path — once in the Ed25519 precompile ix, once in `BatchMatchPair`.
5. Worked reference — `OffchainOrderPayload.get_message()`
   (`programs/trading/src/instructions/settle_offchain.rs`): order_id[16] +
   user[32] + energy_amount u64[8] + price_per_kwh u64[8] + side u8[1] +
   zone_id u32[4] + expires_at i64[8] = **77 bytes**. `BatchMatchPair` = 77 + 77 +
   8 + 8 + 16 = **186 bytes**.

---

### Mode 3 — PACKET (size a transaction / find the binding limit)

Goal: does this tx fit, and what caps it — packet bytes or compute?

1. **Enumerate instructions** in the tx (ComputeBudget ixs, Ed25519 precompiles,
   the program ix). For batches note the sysvar order:
   `[Ed_Buyer_0, Ed_Seller_0, Ed_Buyer_1, …, Program_IX]`.
2. **Sum bytes**: Σ (each ix data) + account key indices (1 B each under ALT, else
   32 B) + per-ix header + tx signatures (64 B each) + blockhash/msg header (~80 B).
3. **Sum compute**: per-ix CU (measure via `computeUnitsConsumed`, or cite table 11
   — `settle_offchain_match` = 96,707 CU). Compare Σ vs 1,400,000.
4. **Report the binding limit.** Canonical result: `batch_settle_offchain_match`
   is packet-bound at ~1 pair (2 pairs ≈ 1,292 B > 1,232), even though 1.4M CU
   would allow ~14 pairs. ALT can't help — the weight is ix DATA, not accounts.
5. **State the fix class** if asked: to raise pairs/tx, change signature packing
   (pre-verified sig accounts / off-chain aggregated multisig), not the pair count.
6. Note whether byte figures are **measured** (from a real tx) or **estimated**
   (from struct layout) — the paper marks the ~189 B/sig as an estimate.

---

### Mode 4 — HOPS (map the network path + trust boundary)

Goal: the real network path a payload takes and where the trust boundary is crossed.

1. **Production path** (§4.1): meter → Aggregator Bridge (HTTP, Ed25519 verify,
   DLMS/COSEM, AES-256-GCM) → zone Redis Stream → Trading (CDA) → **Chain Bridge**
   (sole Solana RPC; writes via NATS JetStream `chain.tx.*`, reads via gRPC, mTLS)
   → Anchor programs. Off-chain→on-chain crosses at Chain Bridge only.
2. **Bench path**: the replayer scripts submit **directly to the validator RPC** —
   the `gateway` keypair plays every signer role, collapsing the Chain Bridge/NATS
   hop to measure raw on-chain cost. Always call out this difference when a bench
   number is quoted as if it were the production path.
3. For each hop record: protocol, auth (Ed25519 / mTLS / signer), sync vs async,
   and what it verifies. Mark the trust boundary crossing explicitly.

---

### Output discipline

- Every number traces to `path:line` or is labeled an estimate. No citation = not
  in the answer.
- Prefer a table for byte layouts and a fenced ASCII diagram for flows/hops.
- When a value is a design target (slot time, CU budget) vs a measurement (CU
  consumed, TPS), say which — mirror the paper's care here.
- Cross-reference the paper section the fact backs (§4.7 programs, §4.8 DvP/packet,
  §5.5 CU, §5.8 conservation) when relevant.
