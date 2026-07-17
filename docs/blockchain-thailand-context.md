# GridTokenX — Thailand Energy Market Context

> Load Aggregator hierarchy, regulatory framework, and market structure.
> Last reviewed: 2026-07-17

---

## 1. National Smart Grid Roadmap Anchor

GridTokenX maps to Thailand's Smart Grid Master Plan 2022–2031 (five pillars):

| Pillar | GridTokenX relevance |
|---|---|
| **P1 Demand Response & EMS** | Platform-reuse — DR rail reuses settlement infrastructure |
| P2 RE Forecasting | Out of scope |
| **P3 Microgrid & Prosumer** | **Primary anchor** — P2P prosumer trade + zone/microgrid settlement |
| P4 Energy Storage | Future extension |
| P5 EV Integration | Future extension (ISO 15118 gap) |

Pillar 3 (prosumer trade) is the case in which settlement trust must be distributed — the justification axis for the entire blockchain layer.

**Honest qualifications:** Pillar 3 is a roadmap *target* through 2031, not a present deployed market. Nationwide P2P trade remains impermissible under the Enhanced Single Buyer model. The present lawful surface is zone-local / behind-the-meter trade and REC.

---

## 2. GridTokenX as Settlement Platform

GridTokenX is a **settlement technology platform** deployable by EGAT, MEA, or PEA — it is not a separate private LA entity positioned beneath the utilities. The utilities remain the licenced market operators; GridTokenX provides the blockchain settlement infrastructure they run.

```
EGAT / DRCC   (National Control Center — may adopt GridTokenX nationally)
      │
      │  private WAN · OpenADR 3.0
      │
      ├──── MEA — VTN   (LA#1 · Bangkok + vicinity)
      │          │  operates GridTokenX platform for Bangkok zone
      │          └──── DER owners / prosumers (Bangkok)
      │
      └──── PEA — VTN   (LA#1 · 77 provinces)
                 │  operates GridTokenX platform for provincial zones
                 └──── DER owners / prosumers (provinces)

┌─────────────────────────────────────────────────────────┐
│  GridTokenX — Settlement Technology Platform            │
│  Adoptable and operated by EGAT · MEA · PEA            │
│  Not a separate LA#1 or LA#2 market participant         │
│  The utility running it is the licenced zone operator   │
└─────────────────────────────────────────────────────────┘
```

Where an ERC-licensed private LA#2 exists (future extension), they may also operate the GridTokenX platform under delegation from MEA or PEA for their zone.

### Two Services Enabled by the Platform

When MEA, PEA, or EGAT operates GridTokenX, two settlement services become available. The blockchain plays a different role in each:

```
Utility (zone operator running GridTokenX — counterparty to neither service)
  │
  ├── DR service (existing ERC framework)
  │     negawatt → §97(4) fund compensation via EPPO
  │     one-to-many · state pays · no distrusting counterparty
  │     Chain role: RECORD LAYER only (audit trail, not settlement)
  │
  └── Trade service (P2P settlement)
        energy + REC trades within the zone
        many-to-many · peer pays peer · mutual distrust
        Chain role: SETTLEMENT LAYER (atomic swap)
```

---

## 3. Institutional Roles

| Institution | Thai Name | Role | Blockchain Role |
|---|---|---|---|
| ERC | กกพ Energy Regulatory Commission | Regulator | Governance authority (target: k-of-n multisig); observer node; audit access |
| EGAT / DRCC | กฟผ Electricity Generating Authority | National operator | Consensus node operator; T-REC co-signer; Registry authority; may operate GridTokenX nationally |
| MEA | กฟน Metropolitan Electricity Authority | LA#1 Bangkok | Consensus node; DR Settlement co-signer (Bangkok zone); admission authority; **platform operator for Bangkok** |
| PEA | กฟภ Provincial Electricity Authority | LA#1 Provincial | Consensus node; DR Settlement co-signer (provincial zones); admission authority; **platform operator for provinces** |
| GridTokenX | — | Technology platform provider | Settlement infrastructure deployable by EGAT/MEA/PEA; holds 1 multi-sig vote; NOT an independent LA and NOT a zone operator; provides Anchor programs, Chain Bridge, Aggregator Bridge |
| Licensed private LA#2 | — | Future extension | Bonded aggregator per zone (staked GRX, slashable); could run GridTokenX platform under MEA/PEA delegation |
| DER owners / prosumers | — | Participants | Receive GRID tokens; hold on-chain wallets; submit orders |
| Reserve custodian | Bank under BoT alignment | External | THBG fiat-reserve attestor (separate from param admin) |

**The operating utility is never a counterparty.** The zone operator (MEA/PEA/EGAT running GridTokenX) operates the order book but is absent from escrow and settlement signer sets. This keeps them an infrastructure operator, not a reseller (Enhanced Single Buyer model prohibits reselling).

---

## 4. Where Trade Is Lawful

| Trade type | Permitted today | Notes |
|---|---|---|
| Zone-local / behind-the-meter | ✅ Permitted | Within one transformer/feeder zone (e.g. Koh Tao microgrid) |
| REC trade | ✅ Permitted | Thai SEC Group 1; not electricity, so ESB restriction does not apply |
| Nationwide P2P | ❌ Not permitted | Remains impermissible under Enhanced Single Buyer model |

GridTokenX models trade in full and labels it *simulated zone-local / REC trade*. No deployment for nationwide P2P is claimed.

---

## 5. DR Bid Flow (designed)

```
EGAT/DRCC issues DR order
    │
MEA VTN or PEA VTN → OpenADR 3.0 event to GridTokenX VEN
    │  (GridTokenX platform running inside MEA/PEA infrastructure)
Aggregator Bridge dispatches DER fleet (Smart Grid still in control)
    │
Smart Meters record delta kWh (DLMS/COSEM · Ed25519 · 15-min window)
    │
Platform Bid Engine computes M&V proof → submits to MEA/PEA VTN
    │
MEA or PEA co-signs DR Settlement → on-chain record written
    │
§97(4) fund disburses OFF-CHAIN (EPPO → zone operator → participant)
    │
Disbursement record written ON-CHAIN (ERC audit trail)
```

**Bid pricing constraint:**
```
bid_price ≤ ERC max incentive rate (avoided cost of peaking generation)
```

---

## 6. Zone Assignment

| Zone | Utility | Platform operator | Admission authority |
|---|---|---|---|
| M1 — Bangkok inner | MEA | MEA (running GridTokenX) | MEA (delegated from ERC) |
| M2 — Bangkok metro | MEA | MEA (running GridTokenX) | MEA (delegated from ERC) |
| P1 — Central provinces | PEA | PEA (running GridTokenX) | PEA (delegated from ERC) |
| P2 — Northern provinces | PEA | PEA (running GridTokenX) | PEA (delegated from ERC) |
| P3 — Northeastern provinces | PEA | PEA (running GridTokenX) | PEA (delegated from ERC) |
| P4 — Southern provinces | PEA | PEA (running GridTokenX) | PEA (delegated from ERC) |

MEA co-signs DR settlement **only** for Bangkok zone DERs. PEA co-signs **only** for provincial zone DERs. No cross-zone co-signing.

---

## 7. Private LA#2 Participation (designed — future extension)

A licensed private LA#2 may participate in the GridTokenX network under delegation from MEA or PEA. Admission is the 3-step process specified in [`blockchain-governance.md §2`](blockchain-governance.md#2-consortium-membership--admission): on-chain `admit_aggregator` (creates the zone-scoped `AggregatorEntry` PDA), a slashable bond via `register_validator` + `stake_grx` (≥ 10,000 GRX), and a SPIFFE `BidEngine` cert that permits `submit_mv_proof` + `settle_offchain_match` but never `mint_generation` (AggregatorBridge role — MEA/PEA only).

### Key Differences from Utility (MEA/PEA) Participation

| Capability | MEA / PEA (Utility) | Licensed Private LA#2 |
|---|---|---|
| Consensus / block production | ✅ Yes | ❌ No |
| DR co-sign authority | ✅ Zone co-sign | ❌ No — cannot co-sign DR settlement |
| mint_generation (GRID) | ✅ AggregatorBridge role | ❌ BidEngine role cannot mint |
| submit_mv_proof | ✅ | ✅ |
| settle_offchain_match | ✅ | ✅ BidEngine role |
| Penalty for misbehaviour | Governance removal + audit (no stake slash) | **Bond slash** by program logic + KYC freeze |

### Bond Slashing for Private LA#2

Misbehaviour is punished by slashing the GRX bond (`slash = bond × severity_bps / 10,000`, split between compensation to the harmed party and the ERC / consumer-rebate pool; partial slash → Suspended, full slash → Slashed, no unstake while Active). The full formula, conservation invariant, and open gaps are in [`blockchain-governance.md §2`](blockchain-governance.md#2-consortium-membership--admission).

---

## 8. Penalty Model (designed, asymmetric)

| Actor type | Penalty mechanism |
|---|---|
| State operators (EGAT/MEA/PEA) | Governance removal + audit record — **no stake slash** (lawful/political reality for state enterprises) |
| Private actors / oracle / aggregator nodes | **Bond slash** by program logic + KYC freeze |

Enforced on-chain by whether a bond PDA exists. Validator removal is an on-chain *authorisation*; physical execution is off-chain ops.
