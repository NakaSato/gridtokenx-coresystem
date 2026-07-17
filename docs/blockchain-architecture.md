# GridTokenX — Blockchain Architecture Overview

> **Scope:** System framing, justification, and layered architecture model.
> For topic details see the companion docs listed in §6.
> Status tags: **(impl)** built · **(sim)** localnet/LiteSVM only · **(designed)** not yet built · **(extension)** beyond ERC framework
> Last reviewed: 2026-07-17

---

## 1. Simulation Scope

GridTokenX is a **software co-simulation study** of a consortium energy settlement protocol for the Thai P2P energy market. It is not a deployed production system. No claim implies live operation, regulatory approval, or production readiness.

| What | Status |
|---|---|
| Five Anchor programs (energy-token, governance, oracle, registry, trading) | **(impl)** |
| Chain Bridge — Vault signing, mTLS, single signing path, dual gRPC/NATS | **(impl)** |
| Python AMI/grid co-simulation backend, CINELDI reference-grid ingestion, AC power-flow | **(impl)** |
| On-chain settlement behaviour | **(sim)** — runs on localnet / LiteSVM (Surfpool) |
| 7-node consortium cluster, DR rail, CBL baseline, Dual-Tracker | **(designed)** |

Authoritative specification: [`docs/master-architecture-v3.md`](master-architecture-v3.md)

> **Network Access:** The consortium SVM has NO public endpoints — a private permissioned network, not public Solana mainnet. All RPC, gRPC, NATS, and gossip access requires mTLS client certificates; RPC :8899 is reachable only from Chain Bridge. Full access model: [`blockchain-node-network.md §2`](blockchain-node-network.md#2-network-access-model--private-consortium).

---

## 2. Why a Blockchain — Stated Up Front

The blockchain is justified for **one function only: settlement of trades and value transfers among parties that do not fully trust one another.** It is not justified as a database, a control system, or a general data-integrity layer.

### Where blockchain is justified

When a buyer and seller exchange energy or RECs, the settlement record must be one no single party can rewrite, and the exchange must complete atomically without a trusted intermediary. A permissioned ledger provides this; a single-operator clearing house cannot.

### Where blockchain is NOT necessary (conceded)

- **Data integrity in general** — TEE + signed data handles this without a ledger
- **DR subsidy** — one-to-many disbursement from a state fund; a centralised system suffices. DR is included because it *reuses the same settlement infrastructure*, not because blockchain is required.
- **Single-trust pilot** — if one utility controls everything, even trade settlement could be centralised; the ledger's value emerges when independent private aggregators settle alongside utilities.

### The dividing line — who settles the money

| Service | Chain role | Payer → payee | Mutual distrust | Blockchain required? |
|---|---|---|---|---|
| **Trade service** — P2P energy + REC | **Settlement layer** — atomic swap **(sim)** | peer → peer | ✅ yes (strangers) | ✅ Yes |
| **DR service** — demand response record | **Record layer** — audit trail only **(designed)** | state fund → participant | ❌ none | ❌ No (audit reuse only) |

**LA is operator, never counterparty.** The LA operates matching/clearing but never takes title to energy, holds the traded asset, or is a party to the trade. On-chain, the LA key operates the order book but is absent from the asset-custody and settlement signer sets.

---

## 3. Dual-Layer Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  CONTROL PLANE — Smart Grid (unchanged)                         │
│  EGAT / MEA / PEA — physical dispatch, frequency regulation     │
│  Smart Meters (DLMS/COSEM) · DER Controllers · SCADA           │
│  Blockchain has NO authority here — never commands, never acts  │
└──────────────────────────┬──────────────────────────────────────┘
                           │  verified telemetry ↑  DR events ↓
┌──────────────────────────┴──────────────────────────────────────┐
│  INTERFACE — Aggregator Bridge + Platform Bid Engine            │
│  Ed25519 verify · DLMS decrypt · 15-min aggregation            │
│  OpenADR VEN/BL · M&V proof  (operated by MEA / PEA / EGAT)   │
└──────────────────────────┬──────────────────────────────────────┘
                           │  NATS chain.tx.submit/cancel/mint / gRPC
┌──────────────────────────┴──────────────────────────────────────┐
│  SETTLEMENT PLANE — Blockchain (Solana/Anchor, localnet sim)    │
│  Records what happened · settles who owes whom · mints tokens   │
│  Does NOT command the Smart Grid                                │
└─────────────────────────────────────────────────────────────────┘
```

**Settlement principle:**
```
Smart Grid acts  →  Aggregator Bridge verifies  →  Blockchain records + auto-pays
```

If the blockchain goes offline the Smart Grid continues unaffected. Settlement queues in NATS JetStream and processes on recovery.

---

## 4. Five-Layer Architecture (v3)

| Layer | Purpose | Status |
|---|---|---|
| **L5 Governance & audit** | Consortium thresholds, ERC observation, tamper-evident log | **(designed)** — hash-chained audit log: open gap |
| **L4 Conservation** | Dual-Tracker: GRID minted + REC + DR credited ≤ physical capacity per meter/period | **(designed)** **(extension)** |
| **L3 Settlement rails** | Rail A: energy + REC **(impl core)** · Rail B: demand response **(designed)** | mixed |
| **L2 Oracle integrity** | TEE attestation + Merkle batch — makes data verifiable without trusting one custodian | **(designed)**; oracle/AMI path **(impl)** |
| **L1 Foundation** | Vault signing, mTLS, single signing path, Sealevel per-entity PDAs, NATS write-ahead | **(impl)**; 3 gaps open |

### L1 Foundation — Open Gaps (close first)

1. **Instruction-level parameter policy** — callers can pass arbitrary values; no on-chain bounds check
2. **Hash-chained tamper-evident audit log** — records exist; hash-chain linking them does not
3. **Pre-sign LiteSVM simulation default-on** — off by default; must be manually enabled

### L2 Oracle Integrity — Why It Is Load-Bearing

The real threat is **single-custodian trust**: MEA holds meter data for Bangkok, PEA for provinces. A prosumer settling against that utility has no way to verify the export figure independently of the party that reported it. TEE attestation and Merkle batch make the data feeding settlement verifiable without trusting the custodian alone — making oracle integrity load-bearing for fair settlement, not merely supporting.

Residual boundary: the TEE attests the *computation over a reading*, not that the meter hardware itself reported honestly. Meter-level secure-element attestation is future work and the strongest research hook.

### L3 Rail A — Implemented Core

```
OBIS 2.8.0 export → DLMS gateway → Aggregator Bridge (Ed25519, fail-closed)
  → 15-min batched mints → energy-token: mint GRID (1 GRID = 1 kWh)
  → trading: zone-scoped CDA matching/clearing
  → atomic settlement: GRID ↔ payment swap (simulated on-chain)
  → REC issuance/transfer referencing the same mint batch
```

Four invariants demonstrated in simulation on CINELDI data: **idempotency** · **monotonicity** · **conservation** · **curtailment-safety** (ledger records a curtailment; issues no command).

### Build Sequence (v3 §VII)

1. Close L1 gaps — audit log · parameter policy · pre-sign sim default
2. Harden L2 — TEE + Merkle; name meter-level boundary as future work
3. Refactor Rail A onto closed foundation; idempotency explicit
4. Multi-signer fee-payer pool (removes ≈ 5.33 mint/s single-signer write-lock)
5. Rail B (DR, record-only) · Dual-Tracker · 7-node designed cluster

---

## 5. Four-Layer Cyber-Physical Model

```
I.   Smart Meter  → Ed25519-sign telemetry at source (ATECC608B hardware SE)
II.  Ingestion    → Aggregator Bridge verifies sig → 15-min aggregation → Kafka
III. Exchange     → CDA matching engine → atomic settlement gateway (Chain Bridge)
IV.  Ledger       → Solana programs: Registry · Governance · Trading · Oracle
                                      Treasury · Energy Token
```

---

## 6. Companion Documents

| Topic | File |
|---|---|
| Thailand regulatory context & LA hierarchy | [`blockchain-thailand-context.md`](blockchain-thailand-context.md) |
| Anchor programs & account structures | [`blockchain-smart-contracts.md`](blockchain-smart-contracts.md) |
| Token system — GRID, GRX, REC, THBG, escrow | [`blockchain-tokens.md`](blockchain-tokens.md) |
| DR wholesale + P2P retail market flows | [`blockchain-market-flows.md`](blockchain-market-flows.md) |
| Service connections, ports, protocols | [`blockchain-service-mesh.md`](blockchain-service-mesh.md) |
| Consortium node network & Chain Bridge | [`blockchain-node-network.md`](blockchain-node-network.md) |
| Governance, security & standards compliance | [`blockchain-governance.md`](blockchain-governance.md) |
| Integration tests | [`testing/blockchain-integration-tests.md`](testing/blockchain-integration-tests.md) |
| Master specification (authoritative) | [`master-architecture-v3.md`](master-architecture-v3.md) |
