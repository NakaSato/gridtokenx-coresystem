# ADAPTIONS.md — GridTokenX: Real-World Business Adoption Analysis

> **Purpose.** A deep, evidence-grounded analysis of how the GridTokenX platform — as
> *actually built* in this repository — converts into a real-world business. It maps the
> engineering asset to a market, a regulatory path, revenue models, unit economics, and a
> phased adoption plan. Every technical claim is cited to code or in-repo design docs; every
> market claim is cited to the research reference already vetted in this repo.
>
> **Status.** Strategy document, not a commitment. Regulatory figures and market structure
> are external and move — re-verify before any live decision. Not investment, tax, or legal
> advice.
>
> **Scope.** Platform-wide. Grounding sources:
> [`README.md`](README.md),
> [`gridtokenx-anchor/ARCHITECTURE.md`](gridtokenx-anchor/ARCHITECTURE.md),
> [`gridtokenx-anchor/docs/design/cost-fee-structure.md`](gridtokenx-anchor/docs/design/cost-fee-structure.md),
> [`gridtokenx-anchor/docs/design/role-map.md`](gridtokenx-anchor/docs/design/role-map.md),
> [`gridtokenx-anchor/docs/design/thailand-market-context.md`](gridtokenx-anchor/docs/design/thailand-market-context.md),
> [`docs/product-specs/National.md`](docs/product-specs/National.md),
> [`docs/product-specs/gTHB_ISSUER_SERVICE.md`](docs/product-specs/gTHB_ISSUER_SERVICE.md).

---

## 1. Executive Summary

**What this is.** GridTokenX is a working, permissioned-blockchain platform for **peer-to-peer
(P2P) energy trading** — prosumers sell rooftop-solar surplus directly to nearby consumers,
metered cryptographically, cleared by a market engine, and settled on-chain in a THB-pegged
stablecoin. It is not a whitepaper: the repo contains five production Anchor programs, a
Rust microservice mesh (IAM, Trading, Aggregator Bridge, Chain Bridge, Notification),
smart-meter telemetry ingestion (DLMS/COSEM, Ed25519-signed), demand-response dispatch
(OpenADR 3), and two frontends. See [`README.md`](README.md) §"Core Services".

**The opportunity.** Thailand is mid-transition: PDP2026 (EPC review mid-2026, public
rollout expected **~Q4 2026** — verified July 2026) targets ~60% clean electricity by 2050;
the ERC already runs a regulatory sandbox
testing **Renewable Energy Communities, Direct PPAs, and Third-Party Access (TPA)**; and the
Enhanced Single Buyer model is under fiscal strain (EGAT ~THB 98bn cumulative losses).
The regulatory door for exactly this product is being opened by the regulator itself.
See [`thailand-market-context.md`](gridtokenx-anchor/docs/design/thailand-market-context.md).

**The wedge.** The platform's institution mapping already targets Thailand's *real* bodies —
ERC as regulator/REC-issuer, EGAT wholesale, MEA/PEA distribution, licensed aggregators as
bonded operators — rather than a generic "DAO." See
[`role-map.md`](gridtokenx-anchor/docs/design/role-map.md). This is the difference between a
crypto project and an infrastructure vendor a utility can actually procure.

**The constraint.** The business lives inside a **structurally narrow price spread** —
roughly the gap between the ~2.20 THB/kWh solar buyback floor and the ~4.10 THB/kWh on-peak
retail tariff, minus a ~1.10 THB/kWh wheeling charge that consumes about half of it. Platform
revenue (swap fee + aggregator margin) must fit in what remains — a few tenths of a baht per
kWh. This is why low-overhead architecture is a *business requirement*, not an engineering
preference. See [`cost-fee-structure.md`](gridtokenx-anchor/docs/design/cost-fee-structure.md) §§7, 9–10.

**The honest gap.** The economic engine is production-grade; the **trust-minimization layer
is not finished**. On-chain settlement records a per-batch Merkle commitment but does **not
verify it on-chain** — fraud-proof/challenge-response is proposed, not built. Consensus is
still one shared cluster with local dev keys standing in for EGAT/MEA/PEA/ERC. See
[`ARCHITECTURE.md`](gridtokenx-anchor/ARCHITECTURE.md) §9 `docs/proposed/`. For a
**permissioned pilot with a named operator**, this is acceptable; for a **trustless
multi-party mainnet**, it is the critical-path work.

**Bottom line.** The right first business is **not** "launch a token." It is: become the
**software operator of an ERC-sandbox P2P/Direct-PPA pilot** in one MEA or PEA distribution
zone, priced as a SaaS/transaction-fee infrastructure contract, with the stablecoin
(gTHB/THBG) run as a separately-licensed, fully-reserved issuer. Everything below builds that
case.

---

## 2. The Asset — What Is Actually Built (and What Isn't)

A business case is only as real as the software under it. Inventory, grounded:

### 2.1 Production-ready (shippable in a permissioned pilot)

| Capability | Where | Business meaning |
|---|---|---|
| **Metered energy → on-chain token** | `energy-token` program; Aggregator Bridge 15-min windows; DLMS/COSEM + Ed25519 ingest | Physical kWh becomes a settleable digital asset with cryptographic provenance. This is the core "trust the meter" primitive. |
| **P2P market clearing (CDA)** | `trading` program + Trading Service `trading-engine` | An actual order book + continuous double auction, not a toy. Supports conditional/DCA orders, VPP aggregation. |
| **THB-pegged settlement** | `treasury` program (THBG, 6dp, reserve-attested peg) + gTHB issuer spec | Trades settle in baht, not a speculative token — the only form a utility/regulator will accept. |
| **Identity + custody** | IAM Service (KYC workflow, AES-256-GCM wallet custody, argon2id, scoped JWT) | Onboarding a regulated user base; keys never in plaintext. |
| **Institution-shaped authority** | `governance` program; ERC/EGAT/MEA/PEA role map | Maps to statutory roles, not "governance token holders." Procurement-legible. |
| **Demand response** | Aggregator Bridge OpenADR 3 / OpenLEADR VTN↔VEN, fleet-as-frequency-sensor | A *second* revenue product (grid-services / VPP) on the same telemetry pipe. |
| **RECs (renewable certificates)** | `governance` ERC-1155-style + fungible Token-2022 REC (1 token = 1 MWh) | A *third* product: certificate issuance/trading, ERC-gated. |
| **Signing isolation** | Chain Bridge (sole Solana RPC client, Vault Transit signing, mTLS+RBAC) | No service holds a key; auditable signing boundary — a real security posture, not marketing. |
| **Ops maturity** | 30+ container infra, Prometheus/Grafana/Loki/Tempo/SigNoz, Surfpool mainnet sim, benchmark suites | Operable and measurable, not a demo. |

### 2.2 Proposed / not yet built (the gap to *trustless* multi-party)

From [`ARCHITECTURE.md`](gridtokenx-anchor/ARCHITECTURE.md) §9 and `docs/proposed/`:

- **On-chain root verification / challenge-response.** Batch settlement writes a
  `SettlementRecord` (Merkle root + VAT + total) but the root is **commit-only, not verified
  on-chain**. Off-chain audit consumes it; trustless fraud-proof is **proposed**.
- **Trustless collateral slashing.** Severity-scaled slash + capped victim comp is *in code*;
  multi-victim pro-rata, THBG bonds, and challenge-driven slashing remain design.
- **Real consensus federation.** Wholesale/retail segmentation exists at the *application*
  layer (`ZoneMarket.segment`); actual multi-operator Tower-BFT clusters with EGAT/MEA/PEA
  running real validators is an infrastructure decision, not yet done (dev keys stand in).
- **Live regulatory integrations.** ERC/MEA/PEA are mapped but not integration partners;
  tariff/wheeling figures are external and not final (TPA Code pending).

**Interpretation.** The gap is precisely the difference between the two viable business
phases in §6: a **permissioned pilot** (works today; trust anchored in a named, licensed
operator + audit) versus a **trust-minimized federation** (needs the proposed layer;
justified only once multiple mutually-distrusting institutions co-run the network).

---

## 3. Market Opportunity

### 3.1 Why Thailand, why now

Grounded in [`thailand-market-context.md`](gridtokenx-anchor/docs/design/thailand-market-context.md):

- **Regulator is actively opening the door.** ERC sandbox is *already* testing Renewable
  Energy Communities, Direct PPA, and TPA — the exact primitives this platform implements.
  TPA framework effective since 3 May 2022; NEPC pilot (25 June 2024) capped at **2,000 MW**;
  draft implementing regulations released 3 Oct 2025.
- **Structural strain creates urgency.** ESB losses (~THB 98bn), an 8–12% tariff hike, and a
  contested June 2026 tariff restructuring mean the status quo is politically expensive —
  reform pressure is real, not hypothetical.
- **Policy tailwind.** PDP2026 (~60% clean by 2050), NDC 3.0 net-zero-by-2050, rooftop-solar
  growth straining the single-buyer model. P2P + VPP is a coherent answer to distributed
  supply the ESB can't cleanly absorb.
- **Timing.** PDP2026 moves through EPC in mid-2026 with public rollout targeted **~Q4 2026**
  (re-verified July 2026) — a natural business-development inflection: the plan that
  legitimizes distributed-energy market mechanisms.
- **Buyback quota is *full* — a live demand pull for P2P.** MEA+PEA's combined ~90 MW
  residential net-billing rooftop quota was **filled as of late 2024, new seller applications
  frozen** pending program expansion (re-verified July 2026). Prosumers who install solar now
  have **no grid buyback path** for surplus — P2P is not just cheaper, it is for many the
  *only* route to monetize export. This is the strongest near-term adoption pull in the whole
  analysis, and it exists *today*, independent of PDP2026.

### 3.2 Sizing (order-of-magnitude, not a forecast)

The platform monetizes **cleared P2P volume** (fee-per-kWh) and **fixed operator/SaaS**
contracts, not asset appreciation. A defensible bottom-up frame:

- **Beachhead:** one distribution zone of prosumer rooftop solar (a housing estate,
  industrial park, or campus microgrid). Even a few MW of installed rooftop, trading a
  fraction of daily generation P2P, produces the transaction and grid-service volume a pilot
  needs to prove unit economics.
- **Expansion:** MEA (metro Bangkok) + PEA (provincial) cover essentially all distribution
  customers in Thailand. The TPA pilot's 2,000 MW cap is the *near-term* regulated envelope
  — and there is reported pressure (data centers, renewable developers) to raise it.
- **Revenue per kWh is small but volume is large:** at a few satang/kWh of platform take on
  hundreds of GWh of eventual zone-level P2P throughput, the business is a
  high-volume/thin-margin infrastructure toll — a payments-network shape, not a SaaS-seat
  shape.

> Do not over-anchor on a single TAM number. The honest statement: the *regulated* near-term
> market is the TPA pilot envelope; the *structural* market is all Thai distribution-level
> distributed generation; realizable share is gated by regulatory pace, not by technology.

---

## 4. Business Models & Revenue

The platform supports **four** distinct revenue lines on **one** infrastructure. Diversity
matters because the per-trade spread (§5) is thin — no single line carries the business alone.

### 4.1 Transaction fees (the toll)
- **Swap fee** on GRX→THBG conversion (bps, implemented: `treasury::swap_grx_for_thbg`,
  fee in bps). **Aggregator margin** taken from the price spread at clearing.
- Together these are "the platform's revenue" per
  [`cost-fee-structure.md`](gridtokenx-anchor/docs/design/cost-fee-structure.md) §6–7 — and both
  must fit inside the residual spread. Thin per unit, meaningful at zone scale.

### 4.2 Operator / SaaS licensing (the anchor)
- License the software to **licensed aggregators** (private, per-zone) or to MEA/PEA directly
  as the market-clearing/settlement operator. Fixed + usage-based.
- Aligns with the TPA fixed-cost reality: connection charge (THB 10k), ATC allocation (THB
  125k), annual fee (THB 120k) per
  [`cost-fee-structure.md`](gridtokenx-anchor/docs/design/cost-fee-structure.md) §8. An
  aggregator absorbing those fixed costs needs efficient software — that's the sell.

### 4.3 Grid services / VPP (the second product)
- The same metered fleet is a **demand-response resource**. OpenADR 3 dispatch (built) lets an
  aggregator monetize flexibility (capacity/ancillary payments) with the fleet as its own
  frequency sensor. Revenue independent of P2P trade volume.

### 4.4 Certificates & stablecoin float (adjacencies)
- **RECs**: issuance/trading fees on the fungible REC (1 token = 1 MWh), ERC-gated.
- **gTHB/THBG issuer**: a fully-reserved THB stablecoin (see
  [`gTHB_ISSUER_SERVICE.md`](docs/product-specs/gTHB_ISSUER_SERVICE.md)) earns **reserve float
  / interest** on backing deposits — a regulated, separate business, but a natural adjacency
  that also removes settlement FX/volatility risk. **Run it as its own licensed entity**, not
  bundled into the energy platform's risk surface.

---

## 5. Unit Economics — The Spread Is the Business

From [`cost-fee-structure.md`](gridtokenx-anchor/docs/design/cost-fee-structure.md) §10
(illustrative Type 3–4 On-Peak, all THB/kWh):

```
consumer retail alternative        4.1025   ← must stay below this
  clearing price P*                 2.59
  + wheeling (MEA/PEA, bundled)     1.10     ← ~half the spread, the killer variable
  = consumer energy cost           3.69      (before 7% VAT on energy value)
producer net receipt               2.527     ← must stay above buyback floor
  buyback floor                     2.20
platform take (swap fee + margin)  ~0.06     ← swap 50bps + ~0.05 aggregator margin
```

**What this means for the business:**

1. **The wheeling charge is the single most important external number** and the platform does
   not control it (TPA Code not final; range ~1.07–1.151 THB/kWh). Business models must be
   stress-tested against the top of that range.
2. **The residual margin is a few satang/kWh.** The platform is only viable if operating cost
   per settled kWh is *below* that — which is exactly why batched, low-overhead on-chain
   settlement (one tx per zone per window, Merkle-batched) is a **financial** design choice,
   not a technical flourish (§5 of the cost doc: batching "is what keeps blockchain cost from
   eroding the narrow spread").
3. **VAT is data-only on-chain** (recorded for e-Tax/audit, no on-chain arithmetic
   enforcement — decision D4). The **token-transfer VAT exemption depends on token legal
   classification** (digital token vs e-money — a BoT determination). This is a **material
   business/legal dependency**, not a footnote: misclassification changes the tax stack.

**Sensitivity summary:** the business is *robust* on volume and technology, *fragile* on two
external variables — the final wheeling rate and the token's tax/legal classification. Both
belong in the top-line risk register (§8).

---

## 6. Adoption Pathway — Phased Go-to-Market

The technical gap (§2.2) and the regulatory reality (§3) dictate a **two-phase** shape.
Don't skip Phase 1 to chase "trustless."

### Phase 1 — Permissioned Pilot (0–18 months): *works with today's code*
- **Structure:** one distribution zone (MEA or PEA territory), one licensed aggregator as
  named operator, under the **ERC sandbox / Direct-PPA-TPA pilot** umbrella.
- **Trust model:** anchored in the *licensed operator + audit*, not in trustless consensus.
  The commit-only Merkle settlement record is sufficient for auditable dispute resolution
  because there is a single accountable operator. This is honest and legally cleaner.
- **Prove:** unit economics inside the real wheeling charge; onboarding/KYC at real scale;
  telemetry integrity end-to-end; e-Tax/VAT recording; DR dispatch revenue.
- **Deliverable:** a regulator-reviewable settlement + audit trail and a P&L that shows the
  spread closes with margin to spare.

### Phase 2 — Trust-Minimized Federation (18–36+ months): *needs the proposed layer*
- **Trigger:** multiple mutually-distrusting institutions (EGAT + MEA + PEA + independent
  aggregators) co-operate the network, or the regulator requires trustless verification.
- **Build:** on-chain root verification + challenge/fraud-proof, trustless slashing, real
  multi-operator validator federation (the `docs/proposed/` work).
- **Payoff:** removes the single-operator trust assumption → enables a genuinely open,
  multi-party national market and defensibility against "just use a database" critiques.

### Buyer & channel
- **Primary buyer:** a **licensed aggregator** (fastest to contract) or **MEA/PEA innovation
  units** (slower, larger). Regulator (ERC) is the *enabler/approver*, not the paying customer.
- **Wedge use-cases that shorten the sales cycle:** (a) a housing estate / industrial park
  microgrid where the "grid" is largely private (wheeling exposure minimized); (b) a
  data-center Direct PPA (the population the TPA pilot explicitly targets); (c) a
  university/corporate campus with rooftop solar + EV load.

---

## 7. Regulatory & Compliance Path

The platform's design *anticipates* Thai regulation — this is its strongest non-technical
moat. Concrete requirements:

- **ERC licensing / sandbox admission.** Enter via the existing sandbox (RECs, Direct PPA,
  TPA). The `governance` program already models ERC as the admit/revoke/slash authority and
  REC issuer — align the on-chain authority to a real ERC-controlled multisig (the role map's
  fix #1: point `authority` at a Squads/SPL-governance k-of-n vault; no new code needed, only
  a real key). See [`role-map.md`](gridtokenx-anchor/docs/design/role-map.md) §2.
- **TPA / wheeling.** Operate as a grid-access holder or under an aggregator that is; budget
  the fixed TPA fees (§4.2) and the final wheeling rate into pricing.
- **Digital-asset & stablecoin.** gTHB/THBG must be issued by a **licensed digital-asset
  operator** with **1:1 fully-reserved** THB backing and attestation (the issuer spec's
  invariants: mint-atomicity, burn-before-wire, supply ≤ reserves). Resolve the **BoT
  token-vs-e-money classification** early — it gates the VAT exemption *and* the licensing
  regime.
- **KYC/AML.** IAM already runs KYC workflows and encrypted custody; formalize to Thai
  DA-operator / banking KYC standards for the stablecoin on/off-ramp.
- **Data / metering standards.** DLMS/COSEM (IEC 62056) ingest is standards-compliant —
  a procurement advantage with utilities that speak the same protocol.

---

## 8. Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| **Wheeling rate lands high** (>1.15 THB/kWh) → spread collapses | Critical | Stress-test pricing at top of range; lead with low-wheeling use-cases (private microgrids, campus, on-site Direct PPA) where physical wheeling is minimal. |
| **Token tax/legal reclassification** (e-money vs digital token) | Critical | Resolve BoT classification *before* scaling; keep VAT recording data-only and adaptable (rate is a parameter, not a constant); run gTHB as a separately-licensed entity. |
| **PDP2026 delayed / TPA cap stays low** | High | Phase-1 pilot doesn't need the national market — it needs one zone and one license. De-risk by not depending on the 2,000 MW cap rising. |
| **Trust-minimization gap** (no on-chain fraud-proof) | High for Phase 2 | Phase 1 anchors trust in a licensed operator + audit; build the proposed layer only when multi-party federation demands it. Be transparent — don't claim "trustless" prematurely. |
| **Incumbent inertia (EGAT/ESB)** | High | Position as *enabling* the utility's distributed-supply problem, not disrupting it; sell to MEA/PEA innovation units and aggregators, with ERC as sponsor. |
| **Thin margin vs operating cost** | Medium | The architecture is already low-overhead (batched settlement, per-entity sharding); prove cost-per-settled-kWh in Phase 1 and hold the line. |
| **Stablecoin reserve/peg failure** | Medium | The issuer invariants (supply ≤ reserves, attestation freshness, redeem bounded by vault collateral) are enforced on-chain (`treasury`); pair with regulated bank reserves + independent attestor. |
| **Proprietary license limits ecosystem** | Low–Med | License is `Proprietary © 2026 GridTokenX` (README). Fine for a vendor/operator model; revisit if a partner federation needs shared governance of the code. |

---

## 9. Competitive Positioning & Moats

- **Regulatory-shaped from day one.** Most energy-blockchain projects are generic "P2P energy
  DAOs." This one maps to ERC/EGAT/MEA/PEA statutory roles and Thai tariff/VAT structure.
  That is expensive to replicate and is the actual barrier — not the Solana programs.
- **Physical-to-financial integrity.** Ed25519 per-device signing + DLMS/COSEM standard
  metering + isolated Vault-Transit signing is a credible integrity story a utility can audit.
- **Multi-product on one pipe.** P2P + DR/VPP + RECs + stablecoin float diversify the thin
  per-trade margin. Competitors typically do one.
- **Performance headroom.** Benchmarked, sharded, batched settlement gives cost-per-kWh room
  that a naive on-chain design lacks — directly protective of the margin.
- **Weakness to close:** the trust-minimization layer and *real* multi-operator federation.
  Until then, the honest positioning is "auditable permissioned operator," not "trustless."

---

## 10. Recommended Next Actions (business, not code)

1. **Pick the wedge:** target one low-wheeling use-case (private microgrid / campus /
   data-center Direct PPA) in one MEA or PEA zone.
2. **Secure sandbox entry:** open an ERC sandbox / TPA-pilot conversation; line up a licensed
   aggregator partner (the paying operator).
3. **Resolve the two critical externals:** (a) obtain the applicable wheeling rate for the
   target zone; (b) get a BoT/legal read on gTHB token classification.
4. **Stand up gTHB as a separate licensed issuer** with a named bank reserve partner — don't
   entangle it with the energy platform's risk.
5. **Run a Phase-1 P&L pilot** proving cost-per-settled-kWh sits inside the residual spread at
   the *real* wheeling charge, plus a DR-revenue line.
6. **Scope Phase-2 only after Phase-1 signal:** fund the on-chain verification / fraud-proof /
   federation work when a multi-party deployment actually requires it.

---

## 11. Beyond Thailand (optionality, not plan)

The architecture is Thailand-*tuned* but not Thailand-*locked*: DLMS/COSEM, OpenADR 3, IEEE
2030.5, SPL/Anchor, and a parameterized tariff/VAT/wheeling model are all portable. Markets
with (a) high distributed rooftop solar, (b) an active regulator opening distribution-level
access, and (c) a narrow-but-positive buyback↔retail spread are candidates (parts of SEA, and
liberalizing distribution markets elsewhere). Treat this as *future optionality that raises the
asset's strategic value* — not a reason to dilute the Thai beachhead focus. Win one zone
first.

---

*Grounding note: technical claims cite code/design docs in this repo; market and regulatory
claims cite the in-repo, adversarially-verified research reference. External figures (tariffs,
wheeling, TPA fees, PDP2026 timing) are illustrative and not final — re-verify before any live
commitment. This document is a strategy analysis, not investment, tax, or legal advice.*

---

## Appendix — Verification Log (re-verified 2026-07-12)

**In-repo (code/docs) — all CONFIRMED:**
- Swap fee in bps — `treasury::compute_swap_grx_for_thbg` (`fee_bps: u16`), 25-bps unit test. ✓
- Batch settlement Merkle root is **stored, not verified on-chain** —
  `record_settlement_batch.rs:66` `rec.merkle_root = merkle_root` (commit-only). ✓ "gap" claim holds.
- No on-chain fraud-proof / challenge / `verify_merkle` anywhere in `programs/`. ✓ gap confirmed.
- `ZoneMarket.segment` (0=Retail/1=Wholesale) + `AggregatorEntry.segment` — application-layer
  wholesale/retail split. ✓
- Fungible REC mint = 1 token = 1 MWh, 6 dec — `governance/init_rec_mint.rs`. ✓
- gTHB issuer invariants (1:1 fully-reserved, mint-atomicity, supply ≤ reserves). ✓
- License = Proprietary © 2026 GridTokenX (superproject `README.md:586`). ✓

**External (web, verified 2026-07-12) — CONFIRMED, with two updates folded in above:**
- Retail tariff **3.95 THB/unit May–Aug 2026** (base 3.78 + Ft 0.1623, pre-VAT). ✓ exact.
- Solar net-billing buyback **2.20 THB/kWh**, systems up to 10 kW, up to 10-yr. ✓
  (*Update:* current qualifying size is **10 kW**, not the 5 kW in the older cost-fee doc §2.2.)
- Wheeling **~1.07 THB/kWh** draft (postage-stamp, TPA pilot) — **not concluded**. ✓ matches
  the 1.07–1.151 range; still the #1 external uncertainty.
- Direct PPA / TPA pilot **2,000 MW**, data-center-led. ✓
- VAT **7%** (pre-VAT tariff framing confirmed). ✓
- PDP2026 **~60% clean by 2050**; EPC mid-2026 → **rollout ~Q4 2026**. ✓
  (*Update:* timing refined from "Aug–Sept approval" to "Q4 rollout" above.)
- **New material fact folded into §3.2:** MEA+PEA ~90 MW residential net-billing quota **filled
  since late 2024, applications frozen** → direct demand pull for P2P.

Sources (2026-07-12): [Nation Thailand — ERC 3.95 baht May–Aug](https://www.nationthailand.com/business/economy/40064550),
[NBT — power tariffs + solar buyback](https://thainews.prd.go.th/nbtworld/news/view/1987068/?bid=1),
[Zero Carbon Analytics — net-billing cap](https://zerocarbon-analytics.org/energy/thai-households-with-rooftop-solar-already-save-on-bills-raising-the-net-billing-cap-could-mean-they-save-77-more-than-households-without/),
[Lexology — TPA wheeling charge hearing](https://www.lexology.com/library/detail.aspx?g=a9c36f87-006a-49f0-b226-3891243336d5),
[FOSR Law — TPA Code 2025 / Direct PPA](https://fosrlaw.com/2025/thailand-third-party-access-code-2025/),
[MCG — PDP2026 net-zero targets](https://www.mcg-asia.com/featured-insights/thailand-net-zero-2050-pdp-2026-energy-transition),
[DCD — ERC direct PPA framework](https://www.datacenterdynamics.com/en/news/thai-energy-regulator-reveals-framework-for-direct-renewable-ppas-for-data-centers/).
