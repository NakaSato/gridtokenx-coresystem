# GridTokenX — Governance, Security & Standards

> Multi-sig upgrade authority, consortium admission, ERC audit access, and standards compliance.
> Status: **(impl)** single-sig current · **(designed)** k-of-n multi-sig target
> This file is the canonical home for admission, slashing, audit access, and standards
> compliance — other blockchain docs link here rather than restating.
> Last reviewed: 2026-07-17

---

## 1. Smart Contract Upgrade Authority

### Multi-Sig Design (target)

| Signatory | Vote Weight | Role |
|---|---|---|
| EGAT | 1 | National authority; consortium lead |
| MEA | 1 | Platform operator — Bangkok zones |
| PEA | 1 | Platform operator — provincial zones |
| GridTokenX (GTX) | 1 | Technology platform provider |
| ERC | 0 (observer) | Audit access — no upgrade veto |

**Threshold: 3 / 4.** Any upgrade to settlement formulas, incentive caps, penalty thresholds, or token mint authority requires 3 out of 4 votes (from EGAT + MEA + PEA + GTX). ERC has mandatory notification but no veto. Because MEA and PEA are the zone operators and carry regulatory accountability, their signature carries the operational weight — GTX as platform provider is one of the four, not the lead.

> **Current implementation:** `governance::GovernanceConfig.authority` is a single `Pubkey` with 2-step transfer (`update_authority`). The k-of-n multisig council is the target design. Gap: multi-sig logic not yet implemented on-chain.

### Upgrade Process

```
1. Any signatory (EGAT / MEA / PEA / GTX) may propose an upgrade
   - New program bytecode + changelog
   - Publish to public repo + notify all signatories and ERC

2. ERC reviews for regulatory compliance
   - Notification required (ERC has no veto)
   - 7-day public review period begins

3. 3 of 4 signatories sign upgrade transaction (EGAT + MEA + PEA + GTX)
   - Signatures may arrive in any order
   - 7-day time-lock begins after 3rd signature

4. Deploy to consortium after time-lock expires
   - Historical settlement records are IMMUTABLE — upgrades non-retroactive
   - New program version takes effect for future settlements only
```

---

## 2. Consortium Membership & Admission

### Consensus Node Admission (designed)

```
Admit a new consensus node:
    Requires ERC governance authority k-of-n multisig approval
    New node joins validator set → stake-weight recalculated
    Tower BFT fault thresholds recalculate (update n, f = (n-1)/3)

Current designed topology (v3 §IV.2):
    EGAT×2 + MEA×2 + PEA×2 + ERC×1 observer (stake 0)
    n = 7 consensus nodes + 1 observer
    f = 2 (tolerates 2 faulty/offline nodes)
    Requires 2f+1 = 5 votes to confirm

EGAT stake constraint: EGAT stake < ⅓ total
    → EGAT alone cannot halt the network
```

### Aggregator Node Admission (impl)

The admission process differs between utilities (MEA/PEA) and private LA#2 operators.

**Utility (MEA/PEA) aggregator nodes** are admitted by virtue of regulatory role. They hold the AggregatorBridge SPIFFE cert and can mint GRID and co-sign DR settlement.

**Private LA#2 admission (3-step process):**

```
Step 1: ERC / MEA / PEA calls admit_aggregator on-chain
            governance.admit_aggregator(la2_pubkey, zone)
            → creates AggregatorEntry PDA: [b"aggregator", la2_pubkey]
            → stores assigned zone

Step 2: LA#2 registers on-chain and stakes bond:
            registry.register_validator(la2_pubkey)
            registry.stake_grx(≥ 10,000 GRX)  // MIN_VALIDATOR_STAKE
            → Status: Active (bond is slashable)

Step 3: Consortium operator issues SPIFFE cert to LA#2 services:
            URI SAN: spiffe://gridtokenx.th/prod/la2-bid-engine
            Role: BidEngine
            CAN:    submit_mv_proof + settle_offchain_match
            CANNOT: mint_generation (AggregatorBridge role only — MEA/PEA)
            CANNOT: co-sign DR settlement (utility zone authority only)

Open gap: Steps 1 and 2 are not linked on-chain.
    A self-granted bond without AggregatorEntry is currently possible.
    Fix: register_validator must verify AggregatorEntry PDA exists before accepting bond.
```

### Aggregator Removal & Slashing

```
Fraud proof submitted on-chain (any network-admitted participant may submit):
    registry.slash_validator(severity_bps)
        slash = bond × severity_bps / 10,000
        compensation = min(slash, proven_loss)  → harmed party
        remainder → slash_destination (ERC / consumer-rebate pool)

    Invariant: slash == compensation + remainder  (enforced by program)
    Partial slash → Suspended
    Full slash    → Slashed → governance.revoke_aggregator (ERC)
    Cannot unstake while Active (slash-escape prevention)

Slash-escape gap (open):
    An aggregator can unstake before misbehaviour is detected.
    Fix: block unstake below MIN_VALIDATOR_STAKE while Active;
         or keep slashable regardless of status.

Penalty model is asymmetric by actor type:
    State validators (EGAT/MEA/PEA): governance removal + audit record only
        (no stake slash — reflects lawful/political reality for state enterprises)
    Private LA#2 operators: bond slash by program logic + KYC freeze
```

---

## 2.5 Access Control Matrix

This matrix shows what each participant can do on the network and on-chain. "Public" means from the public internet without network admission.

| Capability | EGAT | MEA | PEA | ERC | GTX | LA#2 Private | Public |
|---|---|---|---|---|---|---|---|
| Block production | ✅ | ✅ | ✅ | — | ❌ | ❌ | ❌ |
| Gossip network | ✅ | ✅ | ✅ | — | ❌ | ❌ | ❌ |
| Multi-sig upgrade | ✅ 1 vote | ✅ 1 vote | ✅ 1 vote | notify only | ✅ 1 vote | ❌ | ❌ |
| `admit_aggregator` | delegate | ✅ zone | ✅ zone | ✅ | ❌ | ❌ | ❌ |
| `revoke_aggregator` | — | — | — | ✅ | ❌ | ❌ | ❌ |
| `mint_generation` (GRID) | — | ✅ AggBridge | ✅ AggBridge | — | — | ❌ BidEngine cannot | ❌ |
| `mint_rec` (REC) | — | ✅ AggBridge | ✅ AggBridge | ✅ co-sign T-REC | — | ❌ | ❌ |
| `submit_order` | — | ⚠ via Bid Engine | ⚠ via Bid Engine | — | — | ✅ BidEngine | ❌ |
| `settle_offchain_match` | — | ✅ | ✅ | — | — | ✅ BidEngine | ❌ |
| `submit_mv_proof` (DR) | — | ✅ | ✅ | — | — | ✅ BidEngine | ❌ |
| DR co-sign (zone authority) | — | ✅ Bangkok | ✅ Provincial | — | — | ❌ | ❌ |
| `slash_validator` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (anyone network-admitted) | ❌ no network access |
| `unstake_grx` | — | — | — | — | — | ⚠ blocked while Active | ❌ |
| On-chain account read | ✅ | ✅ | ✅ | ✅ mTLS cert | ✅ | ✅ mTLS cert | ❌ no access |
| Chain Bridge gRPC :5040 | ✅ | ✅ | ✅ | ✅ mTLS cert | ✅ | ✅ mTLS cert | ❌ |
| THBG reserve attestation | — | — | — | — | — | ❌ | ❌ (Bank/BoT only) |
| Run Aggregator Bridge | — | ✅ | ✅ | — | — | ✅ own instance | ❌ |

**Notes:**
- "❌ no network access" for Public means no mTLS cert; cannot reach any endpoint
- "network-admitted" means holding a valid mTLS cert issued by the consortium operator
- GTX holds 1 multi-sig vote but is NOT a zone operator and NOT an LA#2

---

## 3. ERC Audit Access

ERC is observer only — no consensus vote, no upgrade veto. ERC has two audit channels.

### On-Chain (network-admitted read — no per-account ACL)

ERC observer node holds an mTLS certificate for network admission. Once inside the network, the ERC node can read any on-chain account without per-account ACL. This is what "network-admitted read" means — it does NOT mean public access from the internet. The ERC node must be a credentialed consortium member.

```
ERC observer node reads any account (once inside the private network):

    AggregatorEntry PDAs         — all admitted / revoked aggregators + zones
    GenerationMintRecord PDAs    — which meters were minted, when, which window
    SettlementRecord PDAs        — (zone, batch) → merkle_root + vat + total_value
    slash events                 — on registry program accounts
    all token transfers          — GRID, GRX, THBG, REC (SPL transfer records)
    DR event co-sign records     — which LA#1 co-signed which DR event
    governance changes           — authority updates, aggregator admissions
```

### Off-Chain (by request)

```
Aggregator node raw meter readings (pre-chain — pre-aggregation)
Kafka audit log                  — topic audit:9003, 168h rolling → S3 archival
InfluxDB M&V baseline data       — for independent M&V verification
Platform Bid Engine DR event history (operated by MEA/PEA)
```

---

## 4. Network Security Layers

| Layer | Mechanism | Status |
|---|---|---|
| Consensus node connectivity | Firewall: gossip ports (8001-8009 UDP) restricted to consortium member IP ranges only | **(designed)** |
| Node-to-node gossip | Noise protocol encryption | **(impl)** (inherited from Solana SVM) |
| Application → RPC node | mTLS client certificate (Chain Bridge only; NOT public) | **(impl)** |
| NATS envelope auth | P256 signed per-service payload; SPIFFE cert required | **(impl)** — `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true` in prod |
| Transaction signing | Vault Transit HSM; private keys never in process memory | **(impl)** |
| Application RBAC | SPIFFE SAN from mTLS cert → ServiceRole → instruction permission | **(impl)** |
| Smart contract upgrades | Multi-sig 3/4 + 7-day time-lock | **(designed)** |
| ERC audit | Observer node: network-admitted read; mTLS cert required for admission | **(impl)** — SVM read (no per-account ACL once inside) |

---

## 5. Standards Compliance

| Standard | Domain | Status | Notes |
|---|---|---|---|
| IEC 62056 / DLMS/COSEM | Metering | ✅ Full | Only meter protocol; AES-256-GCM per device; CRC-32 + version check |
| OpenADR 3.0 | Demand Response | ✅ Full | VEN client + BL/VTN; OAuth 2.0; Redis event dedup |
| Thai Smart Grid Master Plan (ERC) | Regulatory | ✅ Full | LA#1/LA#2 hierarchy; ERC incentive cap; zone separation |
| Ed25519 / AES-256-GCM / mTLS | Cybersecurity | ✅ Full | Fail-closed device signing; per-device keys; service mesh mTLS |
| IEC 62351 | Cybersecurity | ⚠️ Partial | Crypto present; gap: IEC 62351-8 role lifecycle docs + key rotation |
| IEEE 2030.5 (SEP 2.0) | DER Control | ⚠️ Partial | DERControl adapter present; gap: Billing + Pricing Function Sets |
| NIST Smart Grid Model | Architecture | ⚠️ Partial | Customer/Markets/Service Provider covered; Operations domain (SCADA) not linked |
| IEC 61968 CIM | Interoperability | ❌ Gap | Custom data model; CIM adapter needed for MEA/PEA DMS integration |
| IEC 62325 | Market Communications | ❌ Gap | CIM-based market message format needed for EGAT market API |
| IEEE 1547-2018 | DER Interconnection | ❌ Gap | Anti-islanding/voltage-freq ride-through not enforced in dispatch config |
| ISO 15118 | EV / V2G | ❌ Gap | Custom gRPC dispatch; ISO 15118-2/20 adapter needed for V2G scale |
| IEC 61850 | Substation Automation | — N/A | GridTokenX operates at DER/prosumer level; substation not in scope |

### Priority Gaps

**P1 — OpenADR Dual-VTN**
`OPENLEADR_VEN_VTN_URL` supports a single VTN endpoint. Production requires separate MEA and PEA connections with zone-based DER routing.

**P1 — IEC 61968 CIM Adapter**
MEA and PEA DMS systems use CIM data models. Without an adapter, LA#1 deep integration requires manual transformation. Mapping target: `Device → Meter/EnergyConsumer/UsagePoint`; `Zone → ServiceDeliveryPoint`.

**P2 — IEEE 2030.5 Pricing Function Sets**
Required for price-signal-based DR programs beyond binary FLEX_UP/FLEX_DOWN dispatch.

**P3 — ISO 15118-2/20 (V2G)**
Required before EV fleet expands beyond EGAT V2G pilot scope.

---

## 6. Three Authority Separations

From `gridtokenx-anchor/docs/design/role-map.md` — the design enforces three clean separations that prevent any single party from controlling the full settlement chain:

| Separation | Description | Why it matters |
|---|---|---|
| **1. Governance ≠ Settlement** | ERC admits aggregators but does not settle trades. Trading program settles trades but cannot admit aggregators. | ERC cannot manipulate prices; the trading engine cannot self-authorize. |
| **2. Zone Operator ≠ Custodian** | The zone operator key (MEA/PEA running GridTokenX, or delegated aggregator) is absent from the escrow signer set. The operator matches orders but never holds the traded asset. | Zone operator cannot steal peer assets; platform can be upgraded without freezing settled funds. |
| **3. Reserve Custodian ≠ Param Admin** | THBG fiat-reserve attestation is held by an independent bank under BoT alignment, not by the `treasury::update_attestation` parameter admin. | No single party can both control the peg rate and attest the reserve backing it. |

---

## 7. Open Security Gaps (L1)

From the v3 master architecture build sequence:

| Gap | Description | Severity | Fix |
|---|---|---|---|
| Instruction-level parameter policy | Callers pass arbitrary values (e.g., wheeling charge, fee BPS); no on-chain bounds check | High | Add tariff-authority co-sign; bound charge ≤ trade value |
| Hash-chained audit log | SettlementRecord PDAs exist; hash-chain *linking* them does not | Medium | Link each record to previous record hash before emit |
| Pre-sign LiteSVM simulation not default-on | Must be manually enabled for testing | Low | Flip default in CI config |
| `admit_aggregator` not linked to bond | Bond and AggregatorEntry PDA are separate; self-granted bond possible | High | `register_validator` must verify `AggregatorEntry` exists |
| `settle_offchain_match` permissionless | No admitted-aggregator signer requirement; no `is_operational` check | High | Add `governance_config` account + operational guard + signer |
| Slash-escape via unstake | Active validator can unstake before misbehaviour detected | High | Block unstake below `MIN_VALIDATOR_STAKE` while `Active` |
