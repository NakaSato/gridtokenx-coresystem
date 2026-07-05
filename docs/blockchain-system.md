# GridTokenX Blockchain System

> ⚠️ **SUPERSEDED — June 2026.** This file has been replaced by focused topic-split documents.
> Do not edit here; edit the relevant topic file instead.
>
> | Topic | New file |
> |---|---|
> | Overview & scope | [`blockchain-architecture.md`](blockchain-architecture.md) |
> | Thailand context & LA hierarchy | [`blockchain-thailand-context.md`](blockchain-thailand-context.md) |
> | Anchor programs | [`blockchain-smart-contracts.md`](blockchain-smart-contracts.md) |
> | Token system & escrow | [`blockchain-tokens.md`](blockchain-tokens.md) |
> | DR & P2P market flows | [`blockchain-market-flows.md`](blockchain-market-flows.md) |
> | Service mesh & connections | [`blockchain-service-mesh.md`](blockchain-service-mesh.md) |
> | Node network & Chain Bridge | [`blockchain-node-network.md`](blockchain-node-network.md) |
> | Governance & standards | [`blockchain-governance.md`](blockchain-governance.md) |
>
> The content below is retained for historical reference only.

---

> **Simulation scope (v3):** GridTokenX is a software co-simulation study, not a deployed
> system. Status tags: **(impl)** built · **(sim)** runs on localnet/LiteSVM · **(designed)**
> specified, not yet built · **(extension)** beyond the ERC framework.
> Authoritative spec: [`docs/master-architecture-v3.md`](master-architecture-v3.md)

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Dual-Layer Architecture](#2-dual-layer-architecture)
3. [Thailand Energy Market Context](#3-thailand-energy-market-context)
4. [Blockchain Network](#4-blockchain-network)
5. [Smart Contracts (Anchor Programs)](#5-smart-contracts-anchor-programs)
6. [Token System](#6-token-system)
7. [Wholesale Market — Demand Response](#7-wholesale-market--demand-response)
8. [Retail Market — P2P Energy Trading](#8-retail-market--p2p-energy-trading)
9. [Service Integration](#9-service-integration)
10. [Governance & Security](#10-governance--security)
11. [Standards Compliance](#11-standards-compliance)
12. [Appendix — Glossary](#12-appendix--glossary)

---

## 1. System Overview

GridTokenX is a blockchain-backed P2P energy trading platform operating in Thailand. The blockchain layer provides:

- **Immutable settlement records** for every energy transaction
- **Automated payment release** via smart contract logic, replacing manual monthly reconciliation
- **Public auditability** — regulators (ERC), prosumers, and DER owners can verify any transaction independently
- **Multi-party trust** — no single entity controls settlement; contract ownership reflects the real regulatory hierarchy

### What Blockchain Does NOT Do

| Misconception | Reality |
|---|---|
| Blockchain commands the Smart Grid | Smart Grid (EGAT/MEA/PEA) retains full physical control. Blockchain only records what happened. |
| Blockchain triggers DER dispatch | Dispatch comes from Smart Grid operators via OpenADR / SCADA. Blockchain records delivery after the fact. |
| Blockchain replaces existing metering | DLMS/COSEM smart meters are unchanged. Blockchain receives aggregated verified readings from the Aggregator Bridge. |
| Real-time settlement on every watt | Settlement batches over 15-minute windows after Smart Grid confirms delivery. |

### Settlement Principle

```
Smart Grid acts  →  Aggregator Bridge verifies  →  Blockchain records + auto-pays
```

If the blockchain layer goes offline, the Smart Grid continues operating normally. Settlement queues and is processed when the layer recovers.

---

## 2. Dual-Layer Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  CONTROL PLANE — Smart Grid (unchanged)                          │
│                                                                  │
│  EGAT / DRCC  ──  MEA DMS  ──  PEA DMS  ──  ERC Monitoring     │
│       │                │              │                          │
│   SCADA / EMS       AMI / VTN      AMI / VTN                    │
│       │                │              │                          │
│  Smart Meters ── DER Controllers ── Physical kWh Flows           │
│  DLMS/COSEM      IEEE 2030.5        (unchanged grid operations)  │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                 ┌─────────┴──────────┐
                 │  INTERFACE LAYER   │
                 │  Aggregator Bridge │  ← Ed25519 verify
                 │  LA#2 Bid Engine   │  ← OpenADR VEN/BL
                 └─────────┬──────────┘
                           │
                           │  NATS JetStream  chain.tx.submit
                           │  gRPC  Chain Bridge :5040
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│  SETTLEMENT PLANE — Blockchain (Solana / Anchor)                 │
│                                                                  │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────┐  │
│  │ Registry        │  │ DR Settlement    │  │ DER Settlement │  │
│  │ Owner: EGAT     │──│ Owner: MEA + PEA │──│ Owner: GTX     │  │
│  │ AggregatorEntry │  │ M&V proof verify │  │ GRID token     │  │
│  │ PDA admit/revoke│  │ incentive release│  │ REC mint / P2P │  │
│  └─────────────────┘  └──────────────────┘  └────────────────┘  │
│                                                                  │
│  Multi-sig Upgrade Authority: 3 / 4 (GTX + EGAT + MEA + PEA)   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 3. Thailand Energy Market Context

### Load Aggregator Hierarchy

Thailand's ERC Smart Grid Master Plan defines two LA tiers:

```
EGAT / DRCC   (National Control Center — frequency regulation)
      │
      │  private WAN  /  OpenADR 3.0
      ├──── MEA — VTN   (LA#1 · Bangkok + vicinity)
      │          │
      │          └──── GridTokenX LA#2  (MEA zone DERs)
      │
      └──── PEA — VTN   (LA#1 · 77 provinces)
                 │
                 └──── GridTokenX LA#2  (PEA zone DERs)
```

| Entity | Tier | Blockchain Role |
|---|---|---|
| ERC | Regulator | Observer — permissionless on-chain audit |
| EGAT / DRCC | National | Owns Registry Contract |
| MEA | LA#1 Bangkok | Co-owns DR Settlement Contract (Bangkok zone) |
| PEA | LA#1 Provincial | Co-owns DR Settlement Contract (provincial zone) |
| GridTokenX | LA#2 | Owns DER Settlement Contract; platform operator |
| DER Owners | Participants | Receive GRID tokens; hold on-chain wallets |

### Why Two Zones Matter

MEA and PEA are legally separate utilities with separate distribution networks. Blockchain zone-splitting mirrors this:
- MEA co-signs DR settlement **only** for Bangkok zone DERs
- PEA co-signs DR settlement **only** for provincial zone DERs
- No cross-zone co-signing — prevents MEA from authorizing PEA payments or vice versa

---

## 4. Blockchain Network

### Platform: Solana

| Property | Value |
|---|---|
| Consensus | Proof of History (PoH) + Tower BFT |
| Finality | ~400ms slot time; ~12s confirmed |
| Throughput | 65,000+ TPS (peak); settlement batch sizes well within limits |
| Smart Contract Framework | **Anchor** (Rust) |
| Token Standard | SPL Token |
| Transaction Signing | Vault Transit (HSM) via Chain Bridge — keys never leave Vault |

### Why Solana

- Sub-second settlement confirmation matches 15-minute metering windows
- SPL Token supports GRID token and REC natively
- Anchor's type-safe account model reduces smart contract bugs
- Low transaction fees allow per-kWh granularity without cost distortion

### On-Chain Programs (mainnet)

| Program | Address (placeholder) | Purpose |
|---|---|---|
| Registry | `RegXXX...` | LA admission/revocation |
| DR Settlement | `DRS1XXX...` | Wholesale incentive settlement |
| DER Settlement | `DERXXX...` | P2P + GRID token distribution |
| GRID Token Mint | `GRIDmint...` | SPL Token mint authority |
| REC Token Mint | `RECmint...` | SPL Token mint authority |

### Chain Bridge — Only Solana Caller

```
All services  →  NATS JetStream  →  Chain Bridge  →  Vault Transit sign  →  Solana RPC
              chain.tx.submit                 (gRPC :5040)           (keys never in app)
```

No service may call Solana RPC directly. Chain Bridge enforces:
1. **RBAC** — only authorized subjects can submit transactions
2. **Dedup** — `claim_or_replay` prevents double-submission
3. **Vault Transit** — private keys managed by HashiCorp Vault; never in application memory
4. **mTLS** — NATS envelope signed with P256 cert, CA-verified (enforced when `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true`)

---

## 5. Smart Contracts (Anchor Programs)

> **Status note (v3):** Programs tagged **(impl)** run on localnet/LiteSVM now.
> Programs tagged **(designed)** are specified but not yet built.
> On-chain atomic swap settlement is **(sim)** — simulated on localnet; real deployment
> would settle fiat through existing utility billing (v3 §II.2).

### 5.1 Registry / Governance Contract **(impl)**

**Owner:** EGAT / ERC (target: k-of-n multisig council)
**PDA seed:** `[b"aggregator", authority_pubkey]`

Controls who participates in the GridTokenX network. All other contracts gate on a valid `AggregatorEntry` PDA.

| Instruction | Authority | Description |
|---|---|---|
| `admit_aggregator` | EGAT only | Create `AggregatorEntry` PDA; assign zone (Mea \| Pea) |
| `revoke_aggregator` | EGAT only | Mark entry revoked; blocks token issuance + DR settlement |
| `update_capacity_limit` | EGAT only | Adjust maximum MW capacity for an LA#2 |
| `get_aggregator_entry` | Anyone | Permissionless read |

**Account: `AggregatorEntry`**

```rust
pub struct AggregatorEntry {
    pub authority: Pubkey,       // GridTokenX signing key
    pub zone: Zone,              // Mea | Pea
    pub capacity_limit_kw: u64,  // regulatory cap
    pub is_active: bool,
    pub admitted_at: i64,        // Unix timestamp
    pub bump: u8,
}

pub enum Zone { Mea, Pea }
```

### 5.2 DR Settlement Contract

**Owner:** MEA + PEA (zone-split co-ownership)  
**Trigger:** LA#2 Bid Engine after LA#1 co-sign

Governs wholesale demand response incentive payments. Incentive only releases after the respective LA#1 co-signs — GridTokenX cannot self-certify delivery.

| Instruction | Authority | Description |
|---|---|---|
| `submit_mv_proof` | GridTokenX (LA#2) | Submit Measurement & Verification proof for a DR event |
| `cosign_proof` | MEA (Bangkok) or PEA (provincial) | Confirm delivery; only the zone's LA#1 may sign |
| `execute_settlement` | Anyone (permissionless after co-sign) | Release incentive; triggers DER Settlement `distribute_tokens` |
| `apply_penalty` | MEA / PEA | Deduct shortfall; applied to next settlement cycle |
| `update_incentive_rate` | Multi-sig 3/4 | Change incentive rate (THB/kWh) |

**Account: `DrEvent`**

```rust
pub struct DrEvent {
    pub event_id: [u8; 32],
    pub zone: Zone,
    pub baseline_kwh: u64,
    pub actual_kwh: u64,
    pub shortfall_kwh: u64,
    pub incentive_thb_lamports: u64,
    pub mv_submitted_at: i64,
    pub cosigned_at: Option<i64>,
    pub settled_at: Option<i64>,
    pub state: DrEventState,
}

pub enum DrEventState {
    MvSubmitted,
    Cosigned,
    Settled,
    Penalized,
}
```

**Penalty logic:**

```
if actual_kwh / baseline_kwh < PENALTY_THRESHOLD (default 80%)
    shortfall_kwh = baseline_kwh - actual_kwh
    penalty = shortfall_kwh × incentive_rate × PENALTY_MULTIPLIER
    deduct from next settlement cycle
```

### 5.3 DER Settlement Contract

**Owner:** GridTokenX  
**Trigger:** DR Settlement Contract (downstream cascade) or P2P trade confirmation

Manages GRID token distribution and P2P retail settlement. Trust comes from publicly readable on-chain code, not from trusting GridTokenX.

| Instruction | Authority | Description |
|---|---|---|
| `distribute_tokens` | DR Settlement (CPI) or GridTokenX | Proportional GRID token mint to each contributing DER owner |
| `settle_p2p_trade` | Trading Service (via Chain Bridge) | Atomic P2P settlement: GRID tokens buyer→seller + REC mint seller→wallet |
| `mint_rec` | GridTokenX | REC issuance 1:1 to verified renewable kWh |
| `transfer_tokens` | Token owner | Standard SPL token transfer (hooks: delivery confirmed flag required) |

**Token distribution — DR event:**

```
total_payout_tokens = actual_kwh × incentive_rate_in_tokens

for each DER in event:
    DER_share = DER_contributed_kwh / total_delivered_kwh
    mint(DER_owner_wallet, total_payout_tokens × DER_share)
```

### 5.4 Multi-Sig Upgrade Authority

| Signatory | Vote Weight | Role |
|---|---|---|
| GridTokenX | 1 | Platform operator |
| EGAT | 1 | National authority |
| MEA | 1 | LA#1 Bangkok zone |
| PEA | 1 | LA#1 provincial zone |
| ERC | 0 (observer only) | Audit access — no upgrade veto |

**Threshold: 3 / 4**

Any upgrade to settlement formulas, incentive caps, penalty thresholds, or token mint authority requires 3/4 signatures before deployment. Upgrade timeline: 7-day time-lock after 3rd signature for public review.

---

## 6. Token System

### GRID Token

| Property | Value |
|---|---|
| Standard | SPL Token |
| Mint authority | DER Settlement Contract (Anchor CPI) |
| Decimals | 6 |
| Issuance | Minted on verified energy delivery only |
| Burn | Burned on P2P trade settlement (buyer's tokens transferred to settlement vault, then burned) |

**Earning GRID tokens:**
1. DER delivers energy during a DR event → `distribute_tokens` mints proportional GRID
2. DER sells energy P2P → buyer pays GRID → seller receives GRID
3. REC is minted simultaneously for renewable generation

**Spending GRID tokens:**
1. Buy energy in P2P market → GRID transferred to seller
2. Pay platform fees (future: fee module)
3. Participate in governance voting (future: DAO module)

### REC (Renewable Energy Certificate)

| Property | Value |
|---|---|
| Standard | SPL Token (non-fungible per kWh batch) |
| Mint authority | DER Settlement Contract |
| Issuance | 1 REC per verified kWh from renewable source |
| Scope | Solar PV, battery (if charged renewable), wind |
| Verification | Aggregator Bridge confirms device type + generation profile |

**REC lifecycle:**
```
Renewable DER generates kWh
    → Aggregator Bridge verifies (device type = solar/wind/battery-renewable)
    → Chain Bridge submits mint_rec instruction
    → 1 REC minted to DER owner wallet
    → REC transferable / tradable independently of GRID token
    → Retiring a REC (burn) = proof of renewable consumption for corporate reporting
```

### Token Flow Diagram

```
                         DR Event (wholesale)
DER Owner ──kWh delivered──► Aggregator Bridge
                                    │
                            M&V proof verified
                                    │
                        DR Settlement Contract
                                    │
                         cosign (MEA/PEA) + execute
                                    │
                         DER Settlement Contract
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
              GRID token minted               REC minted
              to DER owner wallet            to DER owner wallet

                         P2P Trade (retail)
Buyer (Prosumer B) ──GRID tokens──► DER Settlement Contract
                                           │
                               settle_p2p_trade confirmed
                                           │
                    ┌──────────────────────┴──────────────────────┐
                    ▼                                             ▼
         GRID tokens → Seller (Prosumer A)            REC → Seller wallet
         (payment for energy delivered)               (certificate transferred)
```

---

## 7. Wholesale Market — Demand Response

### Flow: DR Event → On-Chain Settlement

```
Step 1   EGAT/DRCC issues DR order
            │
            ▼
Step 2   MEA VTN or PEA VTN forwards OpenADR 3.0 event
            │
            ▼
Step 3   Aggregator Bridge receives event (OpenADR VEN listener)
         Redis dedup prevents double-processing
            │
            ▼
Step 4   Aggregator Bridge dispatches DER fleet
         (OpenADR BL to VPP-registered DERs / IEEE 2030.5 / gRPC)
         Smart Grid remains in control — blockchain not involved yet
            │
            ▼
Step 5   Smart Meters record delta kWh during event window
         (DLMS/COSEM · Ed25519-signed · 15-min aggregation)
            │
            ▼
Step 6   Aggregator Bridge verifies Ed25519 signatures (fail-closed)
         Decrypts DLMS payload (AES-256-GCM per device)
         Writes baseline + actual to InfluxDB (M&V source of truth)
            │
            ▼
Step 7   LA#2 Bid Engine reads aggregated result from Aggregator Bridge (gRPC)
         Constructs M&V proof: {event_id, baseline_kwh, actual_kwh, zone, timestamp}
            │
            ▼
Step 8   LA#2 Bid Engine → DR Settlement Contract (via Chain Bridge NATS)
         submit_mv_proof(event_id, baseline_kwh, actual_kwh, zone, signature)
            │
            ▼
Step 9   MEA or PEA (zone-matched) reviews proof → cosign_proof(event_id)
            │
            ▼
Step 10  execute_settlement(event_id) (permissionless after co-sign)
         DR Settlement Contract → CPI → DER Settlement Contract
         distribute_tokens(event_id, recipients[])
            │
            ▼
Step 11  GRID tokens minted to all contributing DER owner wallets
         Proportional to kWh delivered
         REC minted for renewable DERs
```

### Penalty Case

```
if actual_kwh < baseline_kwh × 0.80:
    apply_penalty(event_id, shortfall_kwh)
    GridTokenX penalty_liability += shortfall_kwh × penalty_rate
    deducted from next settlement cycle (not immediate)
    on-chain record: permanent, auditable by ERC
```

### Bid Pricing

LA#2 bid price ≤ ERC-defined maximum incentive (avoided cost of peaking generation):

```
bid_price_thb_per_kw = min(
    aggregated_DER_cost + GridTokenX_margin,
    ERC_max_incentive_rate
)
```

---

## 8. Retail Market — P2P Energy Trading

### Flow: Prosumer Trade → On-Chain Settlement

```
Step 1   Prosumer A creates sell order
         {kWh: 10, price: 3.50 THB/kWh, window: 14:00–15:00}
         → Trading Service API (:4020)
            │
            ▼
Step 2   CDA matching engine (trading-engine crate)
         matches sell order with Prosumer B buy order
            │
            ▼
Step 3   Trade confirmed in Trading Service DB
         Physical kWh delivery: Smart Grid (MEA/PEA distribution)
         Blockchain not involved yet
            │
            ▼
Step 4   Smart Meter A records export, Smart Meter B records import
         (DLMS/COSEM · Ed25519-signed)
            │
            ▼
Step 5   Aggregator Bridge verifies BOTH meter readings
         confirms agreed kWh delivered
            │
            ▼
Step 6   Trading Service → NATS chain.tx.submit
         settle_p2p_trade{
             trade_id,
             seller: Prosumer_A_pubkey,
             buyer:  Prosumer_B_pubkey,
             kwh:    10,
             price:  3.50,
             window: 14:00–15:00
         }
            │
            ▼
Step 7   Chain Bridge: RBAC → dedup → Vault sign → Solana submit
            │
            ▼
Step 8   DER Settlement Contract: settle_p2p_trade
         ┌──────────────────────────────────┐
         │ GRID tokens Buyer → Seller       │ (payment)
         │ REC minted → Seller wallet       │ (renewable certificate)
         │ Trade record written on-chain    │ (immutable audit)
         └──────────────────────────────────┘
```

### CDA (Continuous Double Auction) Engine

The matching engine implements CDA — the same mechanism used in financial exchanges:

- **Price-time priority**: best price matches first; equal prices resolved by submission time
- **Partial fills**: large orders fill across multiple counterparties
- **Settlement atomicity**: the full matched quantity settles on-chain or nothing does

**No market order risk:** orders are limit orders only. P2P price is always agreed before physical delivery begins.

### What Blockchain Verifies in P2P

| Risk | Without Blockchain | With Blockchain |
|---|---|---|
| Double-spend | Prosumer A could sell same kWh to two buyers | GRID tokens are non-duplicable; same-window detection on-chain |
| Delivery dispute | Manual meter reading reconciliation | Both meter readings must confirm agreed kWh; auto-settle or auto-reject |
| Price tampering | Trading Service DB could be altered | Matched price recorded on-chain at trade time; immutable |
| Regulatory audit | Fragmented utility records | ERC reads any P2P trade history permissionlessly |

---

## 9. Service Integration

### Chain Bridge Integration

All blockchain writes go through Chain Bridge. Services publish to NATS JetStream; Chain Bridge consumes, signs, and submits.

**NATS message envelope (`chain.tx.submit`):**

```json
{
  "instruction": "settle_p2p_trade | distribute_tokens | mint_rec | submit_mv_proof",
  "program": "dex | registry | dr_settlement",
  "accounts": ["<pubkey1>", "<pubkey2>"],
  "data": "<base64-encoded instruction data>",
  "idempotency_key": "<uuid>",
  "submitted_by": "<service-name>",
  "timestamp": 1718000000
}
```

**Chain Bridge processing pipeline:**

```
1. Consume  NATS subject: chain.tx.submit
2. Verify   mTLS cert → CA → SPIFFE SAN → P256 signature
3. RBAC     check submitter authorization for instruction type
4. Dedup    claim_or_replay(idempotency_key) → skip if already submitted
5. Sign     Vault Transit → signed Solana transaction
6. Submit   Solana RPC → confirm
7. Emit     settlement.confirmed or settlement.failed event
```

**Environment variables:**

```env
NATS_URL=nats://nats:4222
CHAIN_BRIDGE_GRPC_URL=http://chain-bridge:5040
CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true
MINT_VIA_CHAIN_BRIDGE=true
VAULT_ADDR=http://vault:8200
VAULT_TOKEN=...
SOLANA_RPC_URL=https://api.mainnet-beta.solana.com
```

### Aggregator Bridge Integration

The Aggregator Bridge is the physical-to-blockchain interface:

```
[Smart Meter] → MQTT mTLS :8883 → [EMQX] → [Aggregator Bridge]
                                                     │
                                          Ed25519 verify (fail-closed)
                                          AES-256-GCM decrypt (per device)
                                                     │
                                           15-min aggregation window
                                                     │
                                    ┌────────────────┴───────────────────┐
                                    ▼                                    ▼
                           NATS chain.tx.submit               InfluxDB :8086 (async)
                           (mint_rec / distribute)             (M&V baseline store)
```

**Fail-closed policy:**

```rust
// Ed25519 verification — if Redis is down, ingest is blocked
match verify_signature(&payload, &pubkey_from_redis) {
    Ok(_)  => proceed_to_decrypt(),
    Err(_) => {
        error!("Ed25519 verify failed — dropping payload");
        return Err(IngestError::SignatureInvalid);
    }
}
```

This ensures no unverified telemetry ever reaches the settlement layer.

### LA#2 Bid Engine Integration (New Service)

```
[Aggregator Bridge :5030] → gRPC pull capacity → [LA#2 Bid Engine]
                                                         │
                                              ┌──────────┴──────────┐
                                              ▼                     ▼
                                         MEA VTN :443          PEA VTN :443
                                         (OpenADR bid)         (OpenADR bid)
                                              │
                                    DR event confirmed
                                              │
                                    submit_mv_proof → Chain Bridge
```

**Required environment variables:**

```env
MEA_VTN_URL=https://mea.vtn.example.th
PEA_VTN_URL=https://pea.vtn.example.th
OPENLEADR_CLIENT_NAME=gridtokenx-la2
DR_BID_MAX_PRICE_THB_PER_KW=500
DR_PENALTY_THRESHOLD_PERCENT=80
```

---

## 10. Governance & Security

### Smart Contract Upgrade Process

```
1. GridTokenX drafts upgrade proposal (new program bytecode + changelog)
2. Publish to public repo + notify all signatories
3. ERC reviews for regulatory compliance (notification required; no veto)
4. 7-day public review period
5. 3 of 4 signatories sign upgrade transaction (GTX + EGAT + MEA + PEA)
6. Deploy to mainnet after 7-day time-lock
7. Historical settlement records unchanged (upgrades non-retroactive)
```

### Security Model

| Layer | Mechanism |
|---|---|
| Device identity | Ed25519 per-device keypair + ATECC608B hardware secure element |
| Meter data | AES-256-GCM per-device encryption (enckey stored in Redis) |
| Service mesh | mTLS between all internal services |
| NATS auth | P256 cert signed envelope; CA + SPIFFE SAN verification |
| Blockchain signing | Vault Transit HSM — private keys never in application memory |
| Smart contract upgrades | Multi-sig 3/4 + 7-day time-lock |
| ERC audit | Permissionless on-chain read access to all settlement records |

### Failure Resilience

| Failure | Grid Impact | Settlement Impact | Recovery |
|---|---|---|---|
| Aggregator Bridge offline | None | Recording pauses | Restart; replay from Kafka |
| Chain Bridge offline | None | Queues in NATS JetStream | Reconnect; NATS processes queue |
| Solana congestion | None | Confirmation delay | Exponential backoff retry |
| Redis unavailable | None | Bridge drops telemetry (fail-closed) | Redis restored; bridge self-heals |
| LA#1 VTN unreachable | No new DR dispatch | No new DR settlement events | Reconnect after DR cooldown |
| Vault unavailable | None | Chain Bridge cannot sign; queues | Vault restored; queue drains |

### Regulatory Audit Access

ERC (Energy Regulatory Commission) has read-only access to all settlement data:

```
On-chain (Solana) — permissionless:
    • All Registry entries (admitted LAs, zones, capacity limits)
    • All DR Settlement events (M&V proof, co-sign, incentive paid)
    • All DER Settlement records (token distributions, P2P trades)
    • All REC mints and transfers

Off-chain (by request):
    • Aggregated metering data from InfluxDB (Aggregator Bridge)
    • Audit log from kafka-audit (168h retention → S3 archival)
    • DR event history from Trading Service / LA#2 Bid Engine
```

---

## 11. Standards Compliance

| Standard | Domain | Status | Notes |
|---|---|---|---|
| IEC 62056 / DLMS/COSEM | Metering | ✅ Full | Only meter protocol; AES-256-GCM per device; CRC-32 + version check |
| OpenADR 3.0 | Demand Response | ✅ Full | VEN client + BL/VTN; OAuth 2.0; Redis event dedup |
| Thai Smart Grid Master Plan (ERC) | Regulatory | ✅ Full | LA#1/LA#2 hierarchy; ERC incentive cap compliance; zone separation |
| Ed25519 / AES-256-GCM / mTLS | Cybersecurity | ✅ Full | Fail-closed device signing; per-device keys; service mesh mTLS |
| IEC 62351 | Cybersecurity | ⚠️ Partial | Crypto present; gap: IEC 62351-8 role lifecycle docs + key rotation |
| IEEE 2030.5 (SEP 2.0) | DER Control | ⚠️ Partial | DERControl adapter present; gap: Billing + Pricing Function Sets |
| NIST Smart Grid Model | Architecture | ⚠️ Partial | Customer/Markets/Service Provider covered; Operations domain (SCADA) not linked |
| IEC 61968 CIM | Interoperability | ❌ Gap | Custom data model; CIM adapter needed for MEA/PEA DMS integration |
| IEC 62325 | Market Communications | ❌ Gap | CIM-based market message format needed for EGAT market API |
| IEEE 1547-2018 | DER Interconnection | ❌ Gap | Anti-islanding / voltage-freq ride-through not enforced in dispatch config |
| ISO 15118 | EV / V2G | ❌ Gap | Custom gRPC dispatch; ISO 15118-2/20 adapter needed for V2G scale |
| IEC 61850 | Substation Automation | — N/A | GridTokenX operates at DER/prosumer level; substation not in scope |

### Priority Gaps

**P1 — OpenADR Dual-VTN**
Current `OPENLEADR_VEN_VTN_URL` supports a single VTN endpoint. Production requires separate MEA and PEA connections with zone-based DER routing.

**P1 — IEC 61968 CIM Adapter**
MEA and PEA DMS systems use CIM data models. Without an adapter, LA#1 deep integration requires manual transformation. Mapping: `Device` → `Meter/EnergyConsumer/UsagePoint`; `Zone` → `ServiceDeliveryPoint`.

**P2 — IEEE 2030.5 Pricing Function Sets**
Required for price-signal-based DR programs beyond binary FLEX_UP/FLEX_DOWN dispatch.

**P3 — ISO 15118-2/20 (V2G)**
Required before EV fleet expands beyond EGAT V2G pilot scope.

---

## 12. Appendix — Glossary

| Term | Definition |
|---|---|
| **GRID** | Native utility token of GridTokenX; minted per verified kWh delivered |
| **REC** | Renewable Energy Certificate; 1 REC = 1 verified kWh from renewable source |
| **CDA** | Continuous Double Auction — matching algorithm for P2P energy orders |
| **DR** | Demand Response — reducing/shifting energy consumption on grid operator request |
| **DER** | Distributed Energy Resource — solar panel, battery, EV charger, flexible load |
| **LA#1** | Load Aggregator Level 1 — MEA (Bangkok) or PEA (provinces) |
| **LA#2** | Load Aggregator Level 2 — private operator (GridTokenX) |
| **M&V** | Measurement & Verification — proof of energy delivered vs committed |
| **VPP** | Virtual Power Plant — aggregated DERs presenting as a single grid resource |
| **VTN** | Virtual Top Node — OpenADR 3.0 server issuing DR events |
| **VEN** | Virtual End Node — OpenADR 3.0 client receiving DR events |
| **BL** | B-Logic — OpenADR 3.0 broker-logic node for dispatching downstream |
| **PDA** | Program Derived Address — deterministic Solana account address |
| **SPL** | Solana Program Library — standard token interface on Solana |
| **CPI** | Cross-Program Invocation — one Anchor program calling another |
| **Fail-closed** | On error, reject the operation rather than allow unverified data through |
| **EGAT** | Electricity Generating Authority of Thailand |
| **MEA** | Metropolitan Electricity Authority (Bangkok) |
| **PEA** | Provincial Electricity Authority (77 provinces) |
| **ERC** | Energy Regulatory Commission — Thai energy regulator |
| **DRCC** | Demand Response Coordination Center (EGAT) |
| **DLMS/COSEM** | IEC 62056 smart meter communication standard |

---

*GridTokenX Blockchain System — v1.0 — June 2026*  
*See also: [blockchain-architecture.md](blockchain-architecture.md) · [ARCHITECTURE.md](../ARCHITECTURE.md) · [glossary.md](glossary.md)*
