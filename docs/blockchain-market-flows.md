# GridTokenX — Market Flows

> Step-by-step traces for the DR wholesale flow and P2P retail flow.
> Status: **(impl)** trading engine + escrow · **(designed)** DR co-sign + rail B
> Last reviewed: June 2026

---

## 0. Prerequisites — Network & Participant Admission

All market flows require network admission and participant setup before any on-chain action can occur. This is a **private consortium SVM** — there are no public endpoints.

### Network Access

Every participant and service must hold a valid mTLS client certificate to access the network:

- **RPC :8899** — accessible only from Chain Bridge (mTLS cert required)
- **Chain Bridge gRPC :5040** — requires SPIFFE cert + mTLS; accessible to admitted services only
- **NATS :4222** — requires SPIFFE cert + P256 envelope signing
- **Gossip UDP :8001-8009** — firewalled to consortium member IPs (EGAT/MEA/PEA) only
- **Public Internet** — no path in; zero public endpoints exist

### Utility Admission (MEA / PEA)

MEA and PEA are admitted as consensus participants by virtue of their regulatory role. They hold:
- Consensus node credentials (gossip network)
- AggregatorBridge SPIFFE cert (`spiffe://gridtokenx.th/prod/aggregator-bridge`)
- DR settlement co-sign authority (zone-matched)
- `admit_aggregator` authority (delegated from ERC)
- Capability to `mint_generation` and `mint_rec`

### Private LA#2 Admission (3-step process)

```
Step 1: ERC / MEA / PEA calls admit_aggregator on-chain
            → AggregatorEntry PDA created
            Seed: [b"aggregator", la2_pubkey]
            Stores assigned zone

Step 2: LA#2 calls register_validator + stake_grx(≥ 10,000 GRX)
            Status → Active
            Bond is slashable

Step 3: Consortium operator issues SPIFFE cert
            URI SAN: spiffe://gridtokenx/service/bid-engine
            Role: BidEngine
            CAN: submit_mv_proof + settle_offchain_match
            CANNOT: mint_generation (AggregatorBridge role only), DR co-sign
```

---

## 1. Two Market Channels

| Channel | Role | Settlement layer | Trust model |
|---|---|---|---|
| **DR wholesale** | Demand response — fleet-wide negawatt delivery | Record layer only **(designed)** | State fund → participant (one-to-many; no counterparty distrust) |
| **P2P retail** | Prosumer-to-prosumer energy + REC trade | Settlement layer — atomic swap **(sim)** | Peer → peer (many-to-many; mutual distrust) |

The blockchain roles differ **because** the trust structures differ. DR needs only an immutable audit trail; the state §97(4) fund pays one-directionally, and no counterparty holds a competing claim. P2P requires the blockchain's atomic swap because the seller and buyer do not trust each other and there is no trusted clearing house.

---

## 2. DR Wholesale Flow (11 steps)

> **Status: (designed).** The sub-flow below is the target architecture. Co-signing, M&V proof submission, and LA#2 Bid Engine are specified; chain settlement is simulated on localnet for the oracle/mint path only.

```
Step 1   EGAT/DRCC issues DR order (frequency deviation / peak anticipation)
            │  OpenADR 3.0 event
            ▼
Step 2   MEA VTN or PEA VTN forwards event to GridTokenX VEN
            │  Zone-matched: MEA → Bangkok zones; PEA → provincial zones
            ▼
Step 3   Aggregator Bridge receives event (OpenADR VEN listener)
            │  Redis dedup prevents double-processing of same event_id
            │  Smart Grid remains fully in control — blockchain not yet involved
            ▼
Step 4   Aggregator Bridge dispatches DER fleet
            │  Signal path: OpenADR BL → VPP-registered DERs
            │  Protocols: IEEE 2030.5 / gRPC / custom adapter
            │  Physical dispatch is GRID COMMAND, not blockchain command
            ▼
Step 5   DERs curtail / shift load during event window
            │  Smart meters record OBIS 2.8.0 export register delta
            │  Ed25519-signed DLMS/COSEM · AES-256-GCM per device
            ▼
Step 6   Aggregator Bridge verifies meter signatures (fail-closed)
            │  Decrypt DLMS payload (per-device key from Redis)
            │  Reject any reading with invalid signature — no fallback
            │  Write baseline + actual kWh to InfluxDB (M&V source of truth)
            ▼
Step 7   15-minute aggregation window closes
            │  LA#2 Bid Engine reads zone totals from Aggregator Bridge (gRPC)
            │  Computes M&V proof: {event_id, baseline_kwh, actual_kwh, zone, ts}
            │  LA#2 BidEngine SPIFFE role: can submit_mv_proof; CANNOT mint_generation
            ▼
Step 8   Chain Bridge submits M&V proof on-chain
            │  NATS subject: chain.tx.submit (P256 signed envelope)
            │  Instruction: oracle.submit_meter_reading + submit_mv_proof
            │  Chain Bridge RBAC validates BidEngine SPIFFE SAN before signing
            ▼
Step 9   MEA or PEA (zone-matched) reviews M&V proof
            │  Co-signs: cosign_proof(event_id)
            │  MEA co-signs ONLY Bangkok zone events
            │  PEA co-signs ONLY provincial zone events
            │  No cross-zone co-signing
            │  Private LA#2 CANNOT co-sign DR settlement
            ▼
Step 10  execute_settlement(event_id) — permitted after co-sign from zone utility
            │  DR Settlement record written on-chain (immutable audit)
            │  §97(4) fund disbursement happens OFF-CHAIN (EPPO → LA → participant)
            │  Disbursement reference written on-chain for ERC audit
            ▼
Step 11  GRID tokens minted proportional to kWh delivered
            │  energy-token.mint_generation (idempotent via GenerationMintRecord PDA)
            │  Mint authority: AggregatorBridge SPIFFE role (MEA/PEA) ONLY
            │  LA#2 BidEngine role CANNOT mint GRID
            │  REC minted for renewable DERs
            └── GRID → each DER owner wallet (proportional to kWh_delivered / total_kwh)
```

### DR Penalty Case

```
If actual_kwh < baseline_kwh × 0.80 (penalty threshold):
    apply_penalty(event_id, shortfall_kwh)
    penalty = shortfall_kwh × incentive_rate × penalty_multiplier
    deducted from next settlement cycle (not immediate seizure)
    on-chain record: permanent; auditable by ERC

Penalty model is asymmetric:
    State validators (EGAT/MEA/PEA): governance removal + audit; no stake slash
    Private LA#2 operators: bond slash by registry.slash_validator
        slash = bond × severity_bps / 10,000
        compensation = min(slash, proven_loss) → harmed party
        remainder → ERC / consumer-rebate pool
        Invariant: slash == compensation + remainder
```

### Bid Pricing

```
bid_price ≤ ERC_max_incentive_rate  (avoided cost of peaking generation)
DR_BID_MAX_PRICE_THB_PER_KW = 500   (env variable, enforced by Bid Engine)
```

---

## 3. P2P Retail Flow (8 steps)

> **Status: (impl) core — (sim) on localnet.** The matching engine (CDA) is implemented. Atomic settlement runs on localnet. In a real deployment, the fiat payment leg would settle through existing utility billing; the on-chain path is simulated.

```
Step 1   Prosumer A creates sell order
            │  {kWh: 10, price: 3.50 THB/kWh, window: 14:00–15:00, zone: M1}
            │  Trading Service API :4020
            │  Prosumers cannot submit directly to chain; LA#2 BidEngine submits on their behalf
            ▼
Step 2   CDA matching engine (trading-engine crate)
            │  Price-time priority: best price first; tie-break by submission time
            │  Partial fills supported: large orders fill across multiple buyers
            │  Matches Prosumer A sell with Prosumer B buy order
            ▼
Step 3   Trade confirmed in Trading Service DB
            │  Physical energy delivery: Smart Grid (MEA/PEA distribution) handles
            │  Blockchain NOT involved in physical dispatch
            ▼
Step 4   Smart Meter A records export; Smart Meter B records import
            │  DLMS/COSEM · Ed25519-signed
            │  Both ends must confirm agreed kWh delivered
            ▼
Step 5   Aggregator Bridge verifies both meter readings
            │  Export delta meter A ≥ agreed kWh + tolerance
            │  Import delta meter B ≥ agreed kWh + tolerance
            │  If mismatch → dispute (not auto-settled)
            ▼
Step 6   Trading Service → NATS chain.tx.submit
            │  settle_offchain_match{
            │      trade_id,
            │      seller: Prosumer_A_pubkey,
            │      buyer:  Prosumer_B_pubkey,
            │      kwh:    10,
            │      price:  3.50,
            │      window: 14:00–15:00
            │  }
            │  Envelope: P256 signed (CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true in prod)
            ▼
Step 7   Chain Bridge pipeline
            │  1. RBAC (TradingService or BidEngine role; SPIFFE SAN from mTLS cert)
            │  2. claim_or_replay(trade_id) — skip if already settled
            │  3. Vault Transit sign (Ed25519; keys never leave Vault)
            │  4. Consortium RPC submit (:8899, mTLS)
            ▼
Step 8   trading.settle_offchain_match → atomic on-chain settlement
            │  open_escrow:   seller GRID + buyer THBG locked in escrow PDA
            │  settle_escrow: both legs transferred atomically (one instruction)
            │     GRID  → Buyer wallet   (payment for energy received)
            │     THBG  → Seller wallet  (fiat-pegged payment received)
            │     REC   → Seller wallet  (renewable certificate, if applicable)
            └── SettlementRecord PDA written (Merkle root + VAT + total)
```

### Atomic Settlement Detail

```
Escrow PDA: [b"escrow", trade_id]
    Holds seller GRID + buyer THBG (program-owned; neither peer controls)

settle_escrow (ONE instruction):
    escrow.GRID  → Buyer
    escrow.THBG  → Seller

Either both transfers complete, or the entire transaction reverts.
No partial settlement possible.
LA key is absent from escrow signer set — LA is operator, never counterparty.
```

### What Blockchain Verifies in P2P

| Risk | Without blockchain | With blockchain |
|---|---|---|
| Double-spend | Prosumer A sells same kWh to two buyers | GRID tokens are non-duplicable; GenerationMintRecord PDA prevents same-window remint |
| Delivery dispute | Manual meter reconciliation | Both meter readings must confirm agreed kWh; auto-settle or auto-reject |
| Price tampering | Trading Service DB could be altered | Matched price locked on-chain at trade confirmation time; immutable |
| Regulatory audit | Fragmented utility records | ERC observer node reads any P2P trade history from SettlementRecord PDAs (network-admitted read; no per-account ACL once inside) |

---

## 4. CDA (Continuous Double Auction) Engine

The matching engine implements CDA — same mechanism used in financial exchanges:

```
Participants submit limit orders only (no market orders):
    sell_order {kWh, min_price, window, zone}
    buy_order  {kWh, max_price, window, zone}

Matching rules:
    1. Same zone (zone-local only — nationwide P2P not lawful under current framework)
    2. Buyer max_price ≥ seller min_price
    3. Same window overlap
    4. Price-time priority: best price first; equal price by submission time
    5. Partial fills: order fills across multiple counterparties

Clearing price: uniform price per matched batch (not each pair's bid/ask)
```

No market order risk: both parties commit to a price limit before physical delivery begins.

---

## 5. Settlement Record (Audit Trail)

Every batch settlement writes a `SettlementRecord` PDA:

```
SettlementRecord PDA: [b"settlement", zone, batch_id]
Fields:
    merkle_root:   Merkle root over all matches in this batch
    vat_amount:    VAT calculated per Thai revenue code
    total_value:   total THBG transferred in this batch
    settled_at:    Unix timestamp (Clock::get())

ERC observer node can read any SettlementRecord (network-admitted read;
    no per-account ACL once inside — requires mTLS cert for network admission).
Aggregator node publishes the full match list off-chain;
the on-chain root is the commitment — fraud proof checks inclusion.
```

---

## 6. Flow Comparison

| Step | DR Wholesale | P2P Retail |
|---|---|---|
| Trigger | EGAT/DRCC order via OpenADR | Prosumer submits order |
| Physical dispatch | Smart Grid via OpenADR BL | Smart Grid (normal distribution) |
| Verification | M&V proof — Aggregator Bridge | Both meter readings confirmed |
| On-chain action | Record (audit) + mint GRID | Settle (atomic swap) + mint GRID |
| Payment path | §97(4) fund OFF-CHAIN (EPPO) | THBG on-chain (simulated) |
| Co-sign required | MEA or PEA zone co-sign | Admitted aggregator **(gap: not yet enforced)** |
| Who can mint | AggregatorBridge role only (MEA/PEA) | AggregatorBridge role only (MEA/PEA) |
| LA#2 role | submit_mv_proof via BidEngine | settle_offchain_match via BidEngine |
| Escrow | None (no counterparty asset) | Escrow PDA (both legs) |
| Blockchain necessity | Audit reuse (not required for DR alone) | Required (mutual distrust) |
