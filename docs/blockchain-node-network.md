# GridTokenX — Blockchain Node Network System Design

> **Consortium / Permissioned Network — NOT public Solana mainnet.**
>
> **Simulation scope (v3):** The 7-node consortium cluster described here is **(designed)** —
> specified and modelled, but not deployed. The current codebase runs on **localnet /
> LiteSVM (Surfpool)**. Consensus behaviour is the stock Solana client's, not a running
> consortium's. See [`docs/master-architecture-v3.md §IV`](master-architecture-v3.md) for
> the full honest statement.
>
> Last reviewed: 2026-07-17

---

## Table of Contents

1. [Why a Consortium Network](#1-why-a-consortium-network)
2. [Network Access Model — Private Consortium](#2-network-access-model--private-consortium)
3. [Node Taxonomy — Two Senses of "Validator"](#3-node-taxonomy--two-senses-of-validator)
4. [Two-Tier Consensus Design](#4-two-tier-consensus-design)
5. [Consortium Member Roles](#5-consortium-member-roles)
6. [Network Topology](#6-network-topology)
7. [Chain Bridge — Application Gateway](#7-chain-bridge--application-gateway)
8. [Aggregator (Validator) Nodes](#8-aggregator-validator-nodes)
9. [Signing Infrastructure (Vault Transit)](#9-signing-infrastructure-vault-transit)
10. [Fault Tolerance & Failure Modes](#10-fault-tolerance--failure-modes)
11. [Environment Tiers](#11-environment-tiers)
12. [Configuration Reference](#12-configuration-reference)

> On-chain programs: see [`blockchain-smart-contracts.md`](blockchain-smart-contracts.md)
> Governance, security & standards: see [`blockchain-governance.md`](blockchain-governance.md)

---

## 1. Why a Consortium Network

GridTokenX operates on a **private, permissioned deployment of the Solana SVM** rather than the public Solana mainnet. Three regulatory and operational constraints drive this decision:

| Constraint | Public Mainnet Problem | Consortium Solution |
|---|---|---|
| **Data privacy** | Electricity usage + VAT data visible to anyone | Consortium RPC; data visible only to authorized nodes |
| **Regulatory control** | EGAT/MEA/PEA cannot control who validates Thai energy transactions | Closed validator set operated by the utilities themselves |
| **Fee predictability** | Public gas market is volatile; settlement economics require stable overhead | Fees governed internally; no auction gas spikes |

### What Changes vs Public Solana

Only the **network and consensus layer** changes. The entire application layer is identical to what would run on public Solana:

```
UNCHANGED:
    Anchor programs (Registry, Governance, Trading, Oracle, Treasury, Energy Token)
    SVM runtime (account model, CPI, instruction processing, SVM state contention limits)
    Token standard (SPL Token / Token-2022)
    Program Derived Addresses (PDA) and account layout
    All enforced invariants (peg ceiling, vault separation, slash conservation)

CHANGED:
    Validator set → closed; only EGAT, MEA, PEA nodes
    Transaction data → private (not publicly visible)
    Fee governance → internal; not volatile gas auction
    Network membership → permissioned admission
```

> **Important:** SVM state-contention limits are a property of the runtime, not the public network. They persist in the consortium deployment. The per-zone account-isolation design (§6) remains necessary.

---

## 2. Network Access Model — Private Consortium

GridTokenX runs on a **private permissioned SVM** — not Solana mainnet.

| Access | Public Internet | Admitted Node (mTLS cert) |
|---|---|---|
| Consensus / block production | ❌ Impossible | ✅ EGAT/MEA/PEA only |
| RPC :8899 | ❌ No public endpoint | ✅ Chain Bridge only |
| Gossip :8001-8009 | ❌ IP firewall | ✅ Consortium IPs only |
| Chain Bridge gRPC :5040 | ❌ Requires mTLS cert | ✅ Admitted services |
| NATS :4222 | ❌ Requires SPIFFE cert | ✅ Admitted services |
| On-chain account data | ❌ No path in | ✅ Read any account (no per-account ACL once inside) |

**"Network-admitted read"** in this document means: once a node has network admission (mTLS cert), it can read any on-chain account without additional per-account permission. It does **not** mean publicly accessible over the internet. There is no public path to any blockchain endpoint.

### ERC Observer Access

The ERC observer node holds an mTLS certificate for network admission. Once inside the network, the ERC node can read any on-chain account without per-account ACL — this is what "permissionless read" means in the context of the SVM. The ERC node cannot reach any blockchain data from the public internet; it must be a credentialed network member.

### Who Holds mTLS Certs

| Party | Network Role | mTLS Cert Issued By |
|---|---|---|
| EGAT consensus nodes | Block production | Consortium operator |
| MEA consensus nodes | Block production | Consortium operator |
| PEA consensus nodes | Block production | Consortium operator |
| ERC observer node | Read-only audit | Consortium operator |
| Chain Bridge | Only app → RPC gateway | Consortium operator |
| Aggregator Bridge (MEA/PEA) | AggregatorBridge SPIFFE role | Consortium operator |
| LA#2 Bid Engine | BidEngine SPIFFE role | Consortium operator (after Step 3 of admission) |
| Trading Service | TradingService SPIFFE role | Consortium operator |
| IAM Service | IamService SPIFFE role | Consortium operator |
| Smart meters | MQTT device cert | Device registration |

---

## 3. Node Taxonomy — Two Senses of "Validator"

The word **"validator"** has two completely different meanings in this system. Conflating them is the most common architectural misunderstanding.

```
  TWO SENSES OF "VALIDATOR" — keep strictly separate

  ┌──────────────────────────┐   ┌──────────────────────────────┐
  │  CONSENSUS NODE          │   │  AGGREGATOR NODE             │
  │  (Solana validator)      │   │  (application "validator")   │
  ├──────────────────────────┤   ├──────────────────────────────┤
  │ Orders txns, agrees on   │   │ Clears one zone's P2P market │
  │ ledger state             │   │ off-chain; staked + slashable│
  │ (PoH + Tower BFT)        │   │                              │
  │                          │   │ Licensed private-sector      │
  │ Run by EGAT / MEA / PEA  │   │ operator — one per zone      │
  │ ONLY — closed set        │   │                              │
  │                          │   │ NOT a block producer         │
  │ GridTokenX does NOT       │   │ NOT in consensus             │
  │ design this layer        │   │ GridTokenX DOES design this  │
  └──────────────────────────┘   └──────────────────────────────┘

  ┌──────────────────────────┐   ┌──────────────────────────────┐
  │  GOVERNANCE AUTHORITY    │   │  CLIENT PARTICIPANT          │
  ├──────────────────────────┤   ├──────────────────────────────┤
  │ Holds on-chain authority │   │ Prosumer / consumer          │
  │ account. Admits/revokes  │   │                              │
  │ aggregators, sets params,│   │ Submits bids + offers        │
  │ slashes misbehaving nodes│   │ Swaps / redeems tokens       │
  │                          │   │                              │
  │ ERC (target: k-of-n      │   │ Cannot stake; runs no node   │
  │ multisig council)        │   │ Only token path: swap GRX    │
  │ NOT in main data path    │   │ to THBC for settlement       │
  └──────────────────────────┘   └──────────────────────────────┘
```

### Summary

| Node Type | Operator | Function | In Consensus? | Status |
|---|---|---|---|---|
| Consensus node | EGAT×2, MEA×2, PEA×2 | Block production, ledger ordering | ✅ Yes | **(designed)** |
| RPC node | Platform operator (MEA / PEA / EGAT running GridTokenX) | Read/write access for application services | ❌ No | **(impl)** local only |
| Aggregator node | MEA / PEA / EGAT (or licensed LA#2 under delegation) | Zone market clearing; stake + slash accountability | ❌ No | **(impl)** |
| Observer node | ERC×1 (stake 0) | Network-admitted read-only audit access (requires mTLS cert; no per-account ACL once inside) | ❌ No | **(designed)** |
| Client | Prosumers, consumers | Submit orders, swap tokens | ❌ No | **(impl)** |

**Designed 7-node topology (v3 §IV.2):**
`EGAT×2 + MEA×2 + PEA×2 + ERC×1 observer (stake 0)` → f = 2 under Tower BFT (n ≥ 3f+1; needs 2f+1 = 5 votes to confirm). EGAT stake < ⅓ total; distinct regions per org.

> **PEA node placement:** PEA covers 77 provinces but does NOT need consensus nodes at each area office. PEA should run **2–3 nodes across regional data centers** for fault tolerance (not data locality). Aggregator nodes (zone market-clearing workers) are the layer that needs geographic distribution — one per zone. These are run by the utility operating the GridTokenX platform (MEA/PEA) or a licensed private LA#2 under their delegation.

---

## 4. Two-Tier Consensus Design

GridTokenX separates consensus into two tiers that answer different questions.

```
  TIER 1 — ORDERING (inherited from Solana SVM)
  ┌────────────────────────────────────────────────┐
  │ "What transactions happened, in what order?"   │
  │                                                │
  │ Mechanism: Proof of History + Tower BFT        │
  │ Designed by: Solana (NOT the GridTokenX team)  │
  │ Guarantee: durable, consistently-observed      │
  │            writes; safety over liveness        │
  └────────────────────────────────────────────────┘

  TIER 2 — SETTLEMENT VALIDITY (designed by GridTokenX)
  ┌────────────────────────────────────────────────┐
  │ "Is this zone's matching + clearing price      │
  │  valid?"                                       │
  │                                                │
  │ Mechanism: optimistic commitment + challenge   │
  │ NOT horizontal Byzantine voting                │
  │                                                │
  │  commit Merkle root → challenge window → adjudicate
  │        │                    │                │
  │  (bind matches)     (fraud proof via    (verify sig
  │                      signed telemetry)  + proof)
  │                                                │
  │               ┌──────────────────────────┐    │
  │               ▼                          ▼    │
  │           SLASH                     FINALIZE  │
  │         (fraud proven)         (window expired)│
  │                                                │
  │ Trust model: "trust, but verify —              │
  │               with stake at risk"              │
  └────────────────────────────────────────────────┘
```

### Tier 1 — Ordering Consensus (Solana SVM)

Provides classical blockchain consensus: which transactions occurred and in what order. Inherited from the SVM. When the Treasury program writes a `SettlementRecord`, Tier 1 guarantees the write is durable and consistently observed by all nodes.

**Tower BFT fault thresholds (inherited):**

```
≥ 1/3 nodes offline or dishonest  →  network HALTS  (safety preserved)
< 2/3 nodes dishonest             →  cannot forge state
≥ 2/3 nodes dishonest             →  would be needed to finalize false ledger

Preference: SAFETY over liveness — halt rather than finalize incorrect state
```

### Tier 2 — Settlement Validity (Challenge-Response)

Answers: is this zone's market-clearing result correct? Uses an **optimistic single-trusted-aggregator** model, not Byzantine voting among multiple aggregators:

1. **Commit** — aggregator publishes Merkle root on-chain, binding all matches in the settlement batch
2. **Challenge window** — any admitted network participant (governance authority or prosumer with network access) may submit a fraud proof (signed telemetry contradicting the root)
3. **Adjudicate** — on-chain Merkle exclusion proof verification (≈3,600 CU); if fraud proven → slash
4. **Finalize** — if window expires without challenge → settlement accepted

**Trust model:** "trust, but verify — with stake at risk." The difference from Byzantine consensus:

| Byzantine consensus | GridTokenX Tier 2 |
|---|---|
| Trust through agreement among many parties | Trust through stake at risk + provable fraud |
| Multiple validators vote; supermajority wins | Single aggregator per zone; slashed if caught cheating |
| Works even if the aggregator is wrong | Requires honest challenger to detect fraud |

> **Current status:** `treasury::record_settlement_batch` (per-`(zone,batch)` `SettlementRecord` PDA with `merkle_root`, `vat_amount`, `total_value`) is implemented. On-chain Merkle root *verification* and challenge-response are **proposed** — gated on settlement-finality / challenge-window redesign since current settlement is immediate.

---

## 5. Consortium Member Roles

The consortium maps directly to Thailand's energy regulatory hierarchy.

```
  CONSORTIUM NETWORK

  ┌─────────────────────────────────────────────────────────────────┐
  │  ERC (กกพ) — Energy Regulatory Commission                       │
  │  Role: Governance Authority (target: k-of-n multisig council)   │
  │  Admits/revokes aggregators · sets params · observer node       │
  │  Network access: mTLS cert required; no per-account ACL         │
  └────────────────────────────┬────────────────────────────────────┘
                               │ governance authority
       ┌───────────────────────┼────────────────────────┐
       │                       │                        │
  ┌────▼─────────┐    ┌────────▼──────┐    ┌────────────▼─────┐
  │  EGAT (กฟผ)  │    │  MEA (กฟน)    │    │  PEA (กฟภ)       │
  │  Transmission│    │  Bangkok metro│    │  77 provinces    │
  ├──────────────┤    ├───────────────┤    ├──────────────────┤
  │ Consensus    │    │ Consensus     │    │ Consensus        │
  │ node(s)      │    │ node(s)       │    │ node(s)          │
  │              │    │               │    │                  │
  │ T-REC issuer │    │ LA#1 VTN      │    │ LA#1 VTN         │
  │ (REC mint    │    │ Admit zones   │    │ Admit zones      │
  │  co-sign)    │    │ M1, M2        │    │ P1, P2 …         │
  │              │    │               │    │                  │
  │ Wheeling     │    │ Distribution  │    │ Distribution     │
  │ tariff signer│    │ loss signer   │    │ loss signer      │
  └──────────────┘    └──────┬────────┘    └────────┬─────────┘
                             │ admit aggregator       │ admit aggregator
                             ▼                       ▼
                    ┌─────────────────┐   ┌──────────────────────┐
                    │ Platform         │   │  Platform             │
                    │ Aggregator Nodes │   │  Aggregator Nodes     │
                    │ (MEA zones)      │   │  (PEA zones)          │
                    │ Operated by MEA  │   │  Operated by PEA      │
                    │ or licensed LA#2 │   │  or licensed LA#2     │
                    └─────────────────┘   └──────────────────────┘

  GridTokenX = settlement technology platform run by MEA / PEA / EGAT
               holds 1 multi-sig vote; NOT a separate LA#2 entity
               NOT a zone operator; provides technology only
```

### On-Chain Authority Mapping (Target Design)

| Institution | On-Chain Role | Program / Account |
|---|---|---|
| ERC | Governance authority — k-of-n multisig | `governance::GovernanceConfig.authority` |
| EGAT | T-REC co-signer for generation mint; transmission wheeling tariff signer | `energy-token` `rec_validator`; `trading` wheeling charge |
| MEA | Consensus node + delegated aggregator admission (Bangkok zones) + distribution loss tariff | Solana cluster; `admit_aggregator` |
| PEA | Consensus node + delegated aggregator admission (provincial zones) + distribution loss tariff | Solana cluster; `admit_aggregator` |
| GridTokenX (platform provider) | Provides settlement infrastructure; holds 1 multi-sig upgrade vote; NOT zone operator | Technology layer; 1 of 4 multisig votes |
| Licensed private LA#2 | Bonded aggregator per zone (where utility delegates to private LA); BidEngine SPIFFE role | `registry::register_validator` |
| Prosumers / consumers | Clients — swap/redeem only; cannot stake | `treasury` swap/redeem; `trading` orders |
| Reserve custodian | Attestor for THBC fiat reserve (separate from param admin; Bank/BoT only) | `treasury::update_attestation` |

---

## 6. Network Topology

### Consortium Network Diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│  CONSORTIUM PRIVATE NETWORK  (permissioned; encrypted; no public access)│
│                                                                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                │
│  │  EGAT        │  │  MEA         │  │  PEA         │                │
│  │  Consensus   │  │  Consensus   │  │  Consensus   │                │
│  │  Validator   │◄►│  Validator   │◄►│  Validator   │                │
│  │  Node(s)     │  │  Node(s)     │  │  Node(s)     │                │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                │
│         │                 │                 │                         │
│         └─────────────────┼─────────────────┘                         │
│                           │  Tower BFT gossip + PoH clock             │
│                           │  (≥ 2/3 stake-weighted supermajority)     │
│                           │  UDP :8001-8009; consortium IPs only      │
│                           │                                           │
│  ┌────────────────────────▼───────────────────────────────────────┐   │
│  │  CONSORTIUM LEDGER STATE (shared by all consensus nodes)       │   │
│  │  Programs: Registry · Governance · Trading · Oracle            │   │
│  │            Treasury · Energy Token                             │   │
│  └────────────────────────┬───────────────────────────────────────┘   │
│                           │                                           │
│  ┌────────────────────────▼───────────────────────────────────────┐   │
│  │  RPC NODES  (read/write access for application services)       │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │   │
│  │  │ GridTokenX   │  │  MEA         │  │  PEA         │         │   │
│  │  │ RPC node     │  │  RPC node    │  │  RPC node    │         │   │
│  │  └──────┬───────┘  └──────────────┘  └──────────────┘         │   │
│  └─────────┼──────────────────────────────────────────────────────┘   │
│            │  (only GridTokenX RPC node exposed to Chain Bridge)      │
│            │  HTTPS mTLS :8899 — NOT public                           │
│  ┌─────────┼──────────────────────────────────────────────────────┐   │
│  │  ERC    │  Observer Node (mTLS cert; network-admitted read-only)│   │
│  │  └──────┘  No per-account ACL once inside; no consensus vote   │   │
│  └────────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────┬────────────────────────────────┘
                                        │ mTLS (Chain Bridge only)
                    ┌───────────────────▼──────────────────────┐
                    │  APPLICATION LAYER  (GridTokenX services) │
                    │                                          │
                    │  ┌──────────────────────────────────┐   │
                    │  │  Chain Bridge  :5040             │   │
                    │  │  ONLY service with RPC access     │   │
                    │  │  Vault Transit sign               │   │
                    │  └──────────┬───────────────┬────────┘   │
                    │             │ NATS writes   │ gRPC reads  │
                    │  ┌──────────▼──┐  ┌─────────▼──────────┐ │
                    │  │ Aggregator  │  │ Trading · IAM      │ │
                    │  │ Bridge      │  │ LA#2 Bid Engine     │ │
                    │  └─────────────┘  └────────────────────┘ │
                    └──────────────────────────────────────────┘
```

### Consensus Node Connectivity

```
Node-to-node (consensus gossip):
    Protocol:   Solana gossip protocol (UDP)
    Encryption: Noise protocol
    Ports:      8001 (gossip), 8002 (transaction forwarding), 8003-8009 (TVU/TPU)
    Access:     Restricted to consortium member IP ranges only (IP firewall)
    Auth:       Each node has a registered vote account keypair; recognized by peers

RPC access (application → ledger):
    Protocol:   HTTPS (JSON-RPC) + WSS (subscriptions)
    Port:       8899 (HTTP), 8900 (WebSocket)
    Access:     Only GridTokenX Chain Bridge may connect; mTLS client cert required
                NOT public — no public endpoint exists at any of these ports
    Rate limit: Internally governed; no public quota
```

### Zone-to-Node Assignment

Each distribution zone maps to the utility that operates it, which determines which consensus node(s) co-own the zone's DR settlement co-signing authority.

| Zone | Utility | Consensus Node Operator | Aggregator Admission Authority |
|---|---|---|---|
| M1 — Bangkok inner | MEA | MEA | MEA (delegated from ERC) |
| M2 — Bangkok metro | MEA | MEA | MEA (delegated from ERC) |
| P1 — Central provinces | PEA | PEA | PEA (delegated from ERC) |
| P2 — Northern provinces | PEA | PEA | PEA (delegated from ERC) |
| P3 — Northeastern provinces | PEA | PEA | PEA (delegated from ERC) |
| P4 — Southern provinces | PEA | PEA | PEA (delegated from ERC) |

---

## 7. Chain Bridge — Application Gateway

Chain Bridge is the only application service that connects to the consortium RPC. All other services reach the ledger through Chain Bridge.

```
  APPLICATION SERVICES
  ┌────────────────┐  ┌────────────────┐  ┌─────────────────┐
  │ Aggregator     │  │ Trading        │  │ LA#2 Bid Engine │
  │ Bridge         │  │ Service        │  │ (new)           │
  └───────┬────────┘  └───────┬────────┘  └────────┬────────┘
          │ NATS              │ NATS               │ NATS
          │ chain.tx.submit   │ chain.tx.submit     │ chain.tx.submit
          └───────────────────┼────────────────────┘
                              ▼
  ┌───────────────────────────────────────────────────────┐
  │  Chain Bridge  :5040                                  │
  │                                                       │
  │  NATS consumer ──┐                                    │
  │                  ▼                                    │
  │  gRPC server ──► sign_and_submit pipeline             │
  │                  │                                    │
  │           1. extract_role (SPIFFE SAN from mTLS cert) │
  │           2. RBAC check                               │
  │           3. PolicyEngine validation                  │
  │           4. claim_or_replay (idempotency dedup)      │
  │           5. Vault Transit sign (Ed25519)             │
  │           6. Consortium RPC submit (:8899, mTLS)      │
  │           7. PostgresAuditStore.record()              │
  └───────────────────────────┬───────────────────────────┘
                              │ HTTPS/WSS  mTLS
                              │ NOT public — mTLS cert required
                              ▼
  ┌───────────────────────────────────────────────────────┐
  │  CONSORTIUM RPC NODE (GridTokenX-operated)            │
  │  :8899 (JSON-RPC)   :8900 (WebSocket)                 │
  └───────────────────────────┬───────────────────────────┘
                              │ Solana gossip
                              ▼
  ┌───────────────────────────────────────────────────────┐
  │  CONSORTIUM CONSENSUS NODES (EGAT + MEA + PEA)        │
  └───────────────────────────────────────────────────────┘
```

### RBAC — Role from SPIFFE mTLS Certificate

The Chain Bridge maps the caller's SPIFFE SAN to a `ServiceRole` and gates instructions per role
(`AggregatorBridge` may mint; `BidEngine` may not; `IamService` is read-only). The full
role-to-instruction table lives in [`blockchain-service-mesh.md §10`](blockchain-service-mesh.md#10-chain-bridge-rbac).

### Blockhash Cache

```
Background task: refresh BlockhashCache every 2 seconds from consortium RPC
sign_and_submit: read from cache (fast path)
                 → fallback to synchronous RPC only if cache empty (rare)

Consortium context: finality time ≈ 400ms slot × ~32 confirmed slots ≈ 12s
                    blockhash validity ≈ 150 slots ≈ 60s
                    2s refresh → always < 4s stale → well within validity window
```

---

## 8. Aggregator (Validator) Nodes

These are the application-layer "validators" — staked, slashable operators of zone market-clearing, not Solana consensus validators.

### Role in Settlement

```
Smart Meters (DLMS/COSEM · Ed25519-signed)
    │
    ▼
Aggregator Node (one per zone)
    │
    ├── Stage 1: Ingest & verify meter signatures vs registered pubkeys
    ├── Stage 2: Aggregate into 15-min window per meter
    ├── Stage 3: Run CDA auction → uniform clearing price → net settlement per participant
    ├── Stage 4: Compute VAT, build Merkle root over all matches
    └── Stage 5: Submit on-chain
                    ├── oracle.aggregate_readings
                    ├── energy-token.mint_generation  (exactly once per meter-window)
                    │   (AggregatorBridge SPIFFE role required; LA#2 BidEngine CANNOT mint)
                    └── treasury.record_settlement_batch (Merkle root + VAT + total)
```

### Exactly-Once Minting (Double Lock)

The most safety-critical guarantee: a meter that generated 5 kWh in window W must produce exactly 5 GRID — never 0 (lost), never 10 (double-mint) — even if two aggregator nodes race. Two layers enforce this: an off-chain Redis `MINTED_SET` (fast local skip) and the on-chain `GenerationMintRecord` PDA (ultimate source of truth — if two nodes race, the first transaction creates the PDA and the second fails). Mechanics in [`blockchain-tokens.md §2`](blockchain-tokens.md#2-grid-token).

### Permissioning & Bond

Utility (MEA/PEA) aggregator nodes are admitted by virtue of their regulatory role. Private
LA#2 operators follow the 3-step admission process (on-chain `admit_aggregator` → bonded
`register_validator` + `stake_grx` ≥ 10,000 GRX → SPIFFE `BidEngine` cert), detailed in
[`blockchain-governance.md §2`](blockchain-governance.md#2-consortium-membership--admission).

### Slashing

Misbehaviour proven within the challenge window triggers `registry.slash_validator(severity_bps)`
against the bond. The slash formula, conservation invariant, status transitions
(Suspended / Slashed), and the open slash-escape gap are specified in
[`blockchain-governance.md §2`](blockchain-governance.md#2-consortium-membership--admission).

---

## 9. Signing Infrastructure (Vault Transit)

Same as the application layer design — all transaction signing goes through HashiCorp Vault Transit. Private keys never enter application process memory.

```
Chain Bridge → POST /v1/transit/sign/gridtokenx-bridge → Vault HSM
                                        │
                               key stays in Vault
                                        │
                               signed transaction bytes returned
                                        │
               Chain Bridge attaches signature → submits to consortium RPC
```

**Vault network placement:**
- Vault `:8200` accessible **only** from Chain Bridge
- Not reachable from DMZ, ERC observer, or external networks
- Consortium RPC node is also not reachable from the public internet

---

## 10. Fault Tolerance & Failure Modes

### Consortium Network Fault Thresholds

```
Node count = n (EGAT + MEA + PEA nodes combined)
Current minimum recommended: n ≥ 4 (consider sub-nodes per utility)

Tower BFT thresholds:
    ≥ 1/3 stake offline or dishonest → network HALTS (ceases to produce blocks)
    < 2/3 stake dishonest           → cannot finalize false transactions
    ≥ 2/3 stake dishonest           → would be needed to forge ledger state

Design implication: with n=3 (one node per utility), one offline node = halt.
Mitigation: each utility runs multiple validator sub-nodes, increasing n.
```

### Failure Response

| Component Fails | Ledger Effect | Application Effect | Recovery |
|---|---|---|---|
| One consensus node (of 3) goes offline | **Network halts** (< 2/3 stake) | All writes queue in NATS; reads return stale | Bring node back online; block production resumes |
| One consensus node (of 4+) goes offline | Reduced redundancy; still produces blocks | Degraded but functional | Restore node |
| RPC node (GridTokenX) goes offline | Ledger unaffected | Chain Bridge cannot submit or read | Restart RPC node; switch to backup RPC |
| Chain Bridge offline | Ledger unaffected | Writes queue in NATS JetStream (durable) | Restart Chain Bridge; NATS drains queue |
| Vault offline | Ledger unaffected | Chain Bridge cannot sign; writes pause | Restore Vault; queue drains automatically |
| Aggregator node offline | Ledger unaffected | Zone market clearing pauses; no new settlements | Restore or failover to backup aggregator |
| Aggregator node cheats | Fraud proof submitted → slash | Settlement rolled back if challenge succeeds | Governance admits replacement aggregator |

### Aggregator Node Failover

Each zone should have a **primary + standby** aggregator pair, both holding valid `AggregatorEntry` PDAs and staked bonds. The exactly-once `GenerationMintRecord` PDA prevents the standby from double-minting if primary partially completed a window.

---

## 11. Environment Tiers

| Tier | Network | Consensus Nodes | Programs | Use |
|---|---|---|---|---|
| **Local Dev** | `localnet` | `solana-test-validator` (single, local) | Deployed via `anchor build` | Developer workstation |
| **CI** | `localnet` or `simnet` | Test validator or Surfpool | Deployed or mainnet clone | Automated tests |
| **Staging** | Private consortium (staging) | EGAT + MEA + PEA staging nodes | Deployed to staging cluster | Pre-production validation |
| **Mainnet Sim** | `simnet` (Surfpool) | In-memory LiteSVM (mainnet state clone) | Mainnet programs | Full E2E without risk |
| **Production** | Private consortium (mainnet) | EGAT + MEA + PEA production nodes | Production programs | Live |

### Local Development

```bash
# Start local single-node validator (handles macOS Apple Silicon ulimit automatically)
just solana-up

# Deploy programs + seed accounts
./scripts/app.sh init

# Re-seed after validator reset (without redeploying programs)
just chain-reseed

# Ports (local dev — no mTLS enforcement in dev mode)
Consortium RPC:        http://localhost:8899
Consortium WebSocket:  ws://localhost:8900
```

> **Dev vs production:** In local dev, `CHAIN_BRIDGE_INSECURE=true` and `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=false` relax the mTLS and NATS signing requirements. In staging and production these are always `false`/`true` respectively. The network access model described in §2 describes production; local dev is intentionally more permissive for iteration speed.

### Mainnet Simulation (Surfpool)

```bash
# Clones consortium mainnet state; runs in-memory; no real transactions
just simnet       # interactive + hot-reload
just simnet-ci    # CI mode (no UI)
just simnet-down

# Chain Bridge selects in-memory provider automatically
SOLANA_NETWORK=simnet
```

### Production Consortium

```env
SOLANA_NETWORK=mainnet
SOLANA_RPC_URL=https://rpc.consortium.gridtokenx.th:8899
CHAIN_BRIDGE_INSECURE=false
CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true
VAULT_ADDR=https://vault.gridtokenx.th:8200
```

---

## 12. Configuration Reference

> For governance, security, and standards compliance details see [`blockchain-governance.md`](blockchain-governance.md).

### Chain Bridge — Consortium-Specific Variables

| Variable | Local Dev | Staging | Production |
|---|---|---|---|
| `SOLANA_NETWORK` | `mainnet` (localnet) | `mainnet` | `mainnet` |
| `SOLANA_RPC_URL` | `http://localhost:8899` | `https://rpc-staging.consortium.gridtokenx.th` | `https://rpc.consortium.gridtokenx.th` |
| `CHAIN_BRIDGE_INSECURE` | `true` | `false` | `false` |
| `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS` | `false` | `true` | `true` |
| `VAULT_ADDR` | `http://localhost:8200` | `https://vault-staging.gridtokenx.th:8200` | `https://vault.gridtokenx.th:8200` |

### Consortium RPC Node Ports

| Port | Protocol | Purpose | Access |
|---|---|---|---|
| 8001 | UDP | Gossip (node-to-node) | Consortium member IPs only (IP firewall) |
| 8002 | UDP | Transaction forwarding | Consortium member IPs only |
| 8003-8009 | UDP | TVU / TPU | Consortium member IPs only |
| 8899 | HTTPS mTLS | JSON-RPC (application access) | Chain Bridge mTLS only — NOT public |
| 8900 | WSS mTLS | WebSocket subscriptions | Chain Bridge mTLS only — NOT public |
| 8003 | HTTP | Validator metrics (Prometheus) | Internal monitoring only |

### Program IDs

The localnet program-ID table lives in
[`blockchain-smart-contracts.md §6`](blockchain-smart-contracts.md#6-program-ids).
Program IDs are authoritative in `gridtokenx-anchor/Anchor.toml`; if any doc table diverges,
`Anchor.toml` is correct.

---

*GridTokenX Blockchain Node Network — v3.0 (Topic Split)*
*See also: [blockchain-architecture.md](blockchain-architecture.md) · [blockchain-smart-contracts.md](blockchain-smart-contracts.md) · [blockchain-governance.md](blockchain-governance.md) · [ARCHITECTURE.md](../ARCHITECTURE.md)*
