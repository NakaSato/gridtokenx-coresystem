# GridTokenX — Master Architecture Specification (v3, unified)

*Unifies master v2 with the trade-settlement LA-adaptation and the chain-per-service/atomic-settlement specs into one document. Supersedes all three. Software-simulation framing throughout; no deployment claim.*
simulation / co-simulation study**, not a production deployment. Every claim is
scoped to what is simulated or implemented; nothing is presented as deployed,
production-ready, or legally operating. The governing principles from v1 are
kept (ledger-only; six invariants); the framing is corrected so that the
contribution is a simulated settlement protocol with verifiable properties, not
a live national system.*

**Status tags:** **(impl)** implemented in the current codebase · **(sim)**
exists only as a simulation/evaluation construct · **(designed)** specified, not
built · **(extension)** beyond the official ERC framework.

---

## Part 0 — Simulation scope statement (read first)

GridTokenX is a **software co-simulation study** of a consortium energy
settlement protocol. It is not deployed, and no claim here implies real-world
operation, regulatory approval, or production readiness. Concretely:

- **What is implemented (impl):** five Anchor programs (energy-token,
  governance, oracle, registry, trading); the Chain Bridge with Vault signing,
  mTLS, single signing path, dual gRPC/NATS ingestion; a Python AMI/grid
  co-simulation backend with CINELDI reference-grid ingestion and AC power-flow.
- **What is simulated (sim):** all on-chain behaviour runs on **localnet /
  LiteSVM (Surfpool)**, not a deployed cluster. The "consortium," the 7-node
  validator set, and on-chain settlement are evaluated in simulation. Solana
  consensus behaviour is the stock client's, not a deployed consortium's.
- **What is designed but not built (designed):** the 7-node cluster, the demand
  response rail, the CBL baseline, the Dual-Tracker, multi-signer fee-payer
  pool, and the three foundation hardening items.
- **Data provenance:** validation uses the published CINELDI Norwegian feeder,
  for solver validation only — not as a representation of the Thai grid.

No regulatory claim is made. Because this is a simulation, design choices that
would face regulatory constraints in deployment (e.g. on-chain payment) are
explored freely and labelled as simulated, not proposed for immediate operation.

---

## Part I — Why a blockchain (the justification, stated up front)

A blockchain is justified here for one function: **settlement of trades and
related value transfers among parties that do not fully trust one another.** It
is not justified as a database, a control system, or a data-integrity layer in
general. We make the case directly, and concede where it does not apply.

### I.1 Where it is justified

The contribution is a **simulated settlement protocol** for energy trades and
renewable certificates. Settlement is the one place where trust genuinely must
be distributed: when a buyer and seller (and, later, competing utility and
private aggregators) exchange value, the record of who owes whom must be one no
single party can rewrite, and the exchange should complete atomically rather
than depend on a trusted intermediary holding funds. This is the property a
permissioned ledger provides and a single-operator clearing house cannot
provide to a distrusting counterparty.

### I.2 Where it is NOT necessary (concede)

- **Data integrity in general** is not a blockchain problem; a TEE plus signed
  data provides integrity at ingestion. The ledger adds value only by making the
  *settlement record* tamper-evident and multi-party-verifiable over time.
- **DR subsidy** is a one-to-many disbursement from a state fund; a centralized
  system suffices. We include it because it can *reuse the same settlement
  infrastructure*, not because a blockchain is necessary for it (see Part III.5).
- **In a single-trust pilot** (one utility, one disburser) even trade settlement
  could be centralized; the blockchain's value appears when independent private
  aggregators settle alongside utilities.

Stating this scope is what makes the positive claim credible: the blockchain is
asked to justify itself for settlement among distrusting parties, nothing more.

### I.3 Policy anchor — where this sits in the national roadmap

Thailand's medium-term smart-grid roadmap (2022–2031) is organised around five
pillars: (1) Demand Response & EMS, (2) RE Forecasting, (3) **Microgrid &
Prosumer**, (4) Energy Storage, (5) EV Integration. GridTokenX is, first and
foremost, infrastructure for **Pillar 3 (Microgrid & Prosumer)**: peer-to-peer
prosumer trade and zone/microgrid settlement are exactly Pillar 3's subject, and
they are also the case in which settlement trust must be distributed (Part I.1).
The DR service (Part II.3, Part IIA.1) maps to **Pillar 1**, where the platform is
*reused* rather than required. Pillars 2, 4, and 5 (forecasting, storage, V2G/EV)
are out of scope here and treated as future extensions.

Two honest qualifications: Pillar 3 is a roadmap *target* (through 2031), not a
present-day deployed market, so GridTokenX addresses Pillar 3 rather than
operating within it; and nationwide P2P remains impermissible today, so the
present lawful surface is zone-local/behind-the-meter and REC (Part II.3). The
anchor establishes that prosumer trade is a *stated national objective*, not an
aim invented by this work — while keeping the simulation framing intact.

---

## Part II — Settlement model (corrected framing)

### II.1 GRID is a clearing asset, not a data record

The deterministic, idempotent mapping from OBIS export registers (1-0:2.8.0) to
SPL Token-2022 mints (1 GRID = 1 kWh) is reframed: minting **creates a tradable
clearing asset**, not a data log entry. A GRID token represents one kWh of
metered generation and is the unit that trades clear against. The mint is the
*start of a settlement chain*, not the recording of telemetry.

### II.2 What settles on-chain vs off-chain

In this simulation, payment settles **on-chain** as an atomic swap, because the
simulation is free of the regulatory constraints that would shape a real
deployment. We are explicit that this is a *simulated* atomic settlement:

```
On-chain (simulated):
  - GRID mint (clearing-asset creation from OBIS)
  - trade matching / clearing (who trades with whom, how much) — zone-scoped CDA
  - atomic settlement: GRID ↔ payment swap, escrow both-legs-or-neither
  - REC ownership (issuance and transfer, non-duplicable)
  - settlement record (tamper-evident, multi-party-verifiable)
Off-chain (acknowledged for real deployment, not simulated here):
  - in a real system, fiat would settle through existing utility billing and the
    §97(4) fund; we note this as the deployment path, but the simulation models
    on-chain atomic settlement to study the protocol's trust properties.
```

The honest statement for the paper: *the simulation evaluates on-chain atomic
settlement to demonstrate the protocol's trustless property; a real deployment
would likely settle fiat off-chain through existing billing, which the
architecture also supports.* Both are stated; neither is over-claimed.

---

## Part II.3 — Trade settlement adapts into the LA layer

Peer trade settlement is adapted into the architecture as a **second service of
the existing Load Aggregator**, alongside the DR service already defined in the
ERC framework. The LA's zone, participant base, and operator role are reused
rather than rebuilt.

```
LA (zone operator; counterparty to neither service)
  ├─ DR service (existing): negawatt → compensation, §97(4) fund via EPPO
  │     one-to-many; state pays; no distrusting counterparty
  │     → settles centrally; blockchain not required
  └─ Trade service (adapted): peer energy + REC trades within the zone
        many-to-many; peer pays peer who do not trust each other
        → settles on-chain, atomically, zone-scoped
        → this is where the blockchain earns its place
```

**The split is the point.** The two services differ in the one dimension that
decides whether a blockchain is justified — who pays whom, and whether they
trust each other:

| | DR service | Trade service |
|---|---|---|
| Payer → payee | state fund → participant | peer → peer |
| Cardinality | one-to-many | many-to-many |
| Mutual distrust | none (state pays) | yes (strangers trade) |
| Settlement | centralized (EPPO) | on-chain atomic |
| Blockchain | not required (audit reuse only) | **required** |

**LA is operator, never counterparty.** In both services the LA provides the
venue and operates matching/clearing, but never takes title to energy, holds the
traded asset, or is a party to the trade. On-chain this is structural: the LA key
operates the order book but is **absent from the asset-custody and settlement
signer sets**. This keeps the LA an operator and not a reseller (which the
Enhanced Single Buyer model forbids).

**Where trade is lawful (stated honestly).** Trade settlement is adapted only
where peer trade is permissible: zone-local / behind-the-meter trade within one
transformer/feeder zone (e.g. a Koh Tao-style microgrid), and REC trade (Thai SEC
Group 1; not electricity, so it does not engage the ESB restriction). REC is the
cleanest case. Nationwide P2P remains impermissible under the ESB model. Because
this is a simulation, the trade service is modelled in full and labelled
*simulated zone-local / REC trade*, never deployed nationwide P2P.

---

## Part IIA — Chain behaviour per service

The LA hosts two services with different trust models, so the chain plays a
different role in each. The dividing line is one step: **settling the money.**

### IIA.1 DR service — chain is a record layer

Because the payer is the §97(4) fund (via EPPO) with no distrusting counterparty,
the chain records facts and an audit trail but does **not** settle the payment.

| Step | On-chain? | What |
|---|---|---|
| 1. DRCC declares event | record-only | logs the event occurred; Call Event command is off-chain |
| 2. Control sheds load | no | SCADA/DERMS act off-chain; may decline for safety; chain has no authority |
| 3. Delivered negawatt | record | meter baseline−actual, TEE-attested, tamper-evident |
| 4. Fund disburses | no | §97(4) → EPPO → LA → participant, real money via existing channels |
| 5. Disbursement record | record | who received how much, for ERC audit — the record, not the payment |

PDAs: `[b"dr_event", zone_id, event_id]`, `[b"negawatt", dr_event, meter_id]`,
`[b"dr_disbursement", dr_event, participant]`. All record-keeping; no value
transfer on-chain. DR has no settlement-trust problem, so the chain adds
tamper-evidence and audit, not settlement.

### IIA.2 Trade service — chain is the settlement layer

Because peers pay peers who do not trust each other, the chain performs the full
settlement, atomically.

| Step | On-chain? | What |
|---|---|---|
| 1. Mint clearing asset | yes | OBIS export → GRID (1=1 kWh), idempotent dedup key |
| 2. Match in zone | yes | LA operates order book (seed `zone_id`); operator, not counterparty |
| 3. Atomic swap | yes | seller GRID ↔ buyer payment, escrowed both-legs-or-neither |
| 4. REC transfer | yes | ownership transfer, non-duplicable |
| 5. Settlement record | yes | hash-chained, ERC observes |

PDAs: mint dedup `[meter_id, register, period]`, `[b"zone_market", zone_id]`,
`[b"escrow", trade_id]`. Full settlement on-chain — the case a permissioned
ledger exists for. (Escrow mechanism: Appendix B.)

### IIA.3 The LA's single key, two roles

The LA Level-1 operator key behaves differently per service, and in **neither**
holds value: in the DR service it writes the disbursement *record* (the LA pays
off-chain through billing); in the Trade service it operates the order book but is
**absent from the escrow and settlement signer sets** — the swap is between the
peers' accounts, escrowed by program logic. Invariant: the LA never takes title
to energy and never holds the asset or funds on-chain.

### IIA.4 The contrast in one line

Everything is the same across the two services except the money: DR disburses
off-chain (trusted state payer), chain only records; Trade settles on-chain
atomically (distrusting peers), chain is the settlement. "Why blockchain" is thus
answered service-by-service: record layer for DR, settlement layer for Trade.

---

## Part III — Layered architecture (build bottom-up)

| Layer | Purpose | Status |
|---|---|---|
| L5 Governance & audit | Consortium thresholds, ERC observation, tamper-evident log | designed (audit log: gap) |
| L4 Conservation | Dual-Tracker: trade + REC + DR within physical capacity | designed (extension) |
| L3 Settlement rails | A energy/REC (impl core), B demand response (designed) | mixed |
| L2 Oracle integrity | TEE attestation + Merkle batch (supporting role) | partly impl |
| L1 Foundation | Instruction policy, pre-sign sim, kept invariants | gaps open |

### III.1 Layer 1 — Foundation (close first)

Three open gaps, all production-blockers even for a credible simulation of
integrity: instruction-level parameter policy **(gap)**; hash-chained
tamper-evident audit log **(gap)**; pre-sign LiteSVM simulation default-on
**(gap)**. Kept invariants **(impl):** Vault signing, mTLS identity, single
signing path, Sealevel per-entity PDAs, zero-copy state, NATS write-ahead +
dual ingestion.

### III.2 Layer 2 — Oracle integrity (supporting, but load-bearing for settlement)

**Threat model — who controls the meter data.** In the Thai structure, smart-
meter data is held by the distribution utilities by territory: MEA in the
metropolitan area, PEA in the provinces, each custodian of the meters in its own
zone; EGAT aggregates this for system operation; ERC regulates without holding
operational data. The relevant threat is therefore **not** "the meter lies" — it
is **single-custodian trust**: settlement reads measurements that one utility
both produces and controls. A prosumer or a private aggregator settling against
that utility has, by default, no way to verify the export figure independently of
the party that reported it.

**What the layer does.** TEE attestation **(designed; oracle/AMI path impl)** and
Merkle batch **(designed)** make the data feeding settlement *verifiable without
trusting the custodian alone*: the reading is attested at source and recorded in
a form multiple parties (including ERC) can check, so a settlement does not rest
on one utility's unverifiable assertion. This is why the layer, though framed as
*supporting* the settlement contribution, is load-bearing for it: settlement can
only be fair if the data it clears against is verifiable by the parties it
adjudicates.

**Residual boundary (stated honestly).** The TEE attests the *computation over a
reading*, not that the meter hardware itself reported honestly; meter-level
secure-element attestation, against a custodian that controls the device, is the
hardest case and is future work. This boundary is the strongest research hook and
is named, not hidden — it is also the precise gap an applied-cryptography
attestation layer (the MEXT/Miyaji direction) addresses.

### III.3 Layer 3 — Rail A: energy + REC settlement (impl core)

```
OBIS 2.8.0 export → DLMS gateway → aggregator bridge (Ed25519, fail-closed)
  → 15-min batched mints → energy-token: mint GRID (clearing asset)
  → trading: zone-scoped CDA matching/clearing
  → atomic settlement: GRID ↔ payment swap (simulated on-chain)
  → REC issuance/transfer referencing the same mint batch
```

Idempotency made explicit: mint keyed by PDA-derived dedup over
`[meter_id, register_reading, period]`; re-submission is a no-op. The four formal
invariants (idempotency, monotonicity, conservation, curtailment-safety) are
*demonstrated in simulation* on CINELDI data (Part VI). Curtailment-safety
means the ledger correctly **records** a curtailment that occurred — it issues
no command.

### III.4 Rail A is the centerpiece; REC is the cleanest case

For the paper, Rail A is the falsifiable contribution. Within it, **REC
settlement** is the cleanest justification: ownership must be non-duplicable and
transferable among parties, which a ledger does well, and REC is the use case
with the firmest standing. Energy trade settlement is the headline; REC is the
tidiest demonstration; both are simulated.

### III.5 Layer 3 — Rail B: demand response (designed, reuses platform)

DR settlement is **designed**, record-only, and aligned to the official ERC
§97(4) framework (NCC market → DRCC/EGAT → LA/MEA-PEA → C&I participant; control
"Call Event" stays off-chain). We are explicit: a blockchain is **not necessary**
for DR subsidy; DR is included because it *reuses the same settlement
infrastructure*, not as a blockchain-necessity claim. CBL baseline (High-X-of-Y,
pre-committed) is designed; baseline gaming is mitigated, not eliminated. DR is
future work, not a claim of the present system.

### III.6 Layer 4 — Dual-Tracker conservation (designed, extension)

`[b"tracker", meter_id, period]`: GRID minted + REC issued + DR credited ≤
physical capacity. The formal seam preventing double-payment across rails.

### III.7 Layer 5 — Governance, audit, regulator (designed)

Squads m-of-n threshold authorization (governance, **not** consensus). Two ERC
keys: funder vs regulator, separated so the regulator never signs settlement.
ERC-regulator: read-only observation + confidential-transfer auditor key +
emergency-freeze seat; never a settlement signer. Hash-chained audit log
underpins audit (gap to close).

---

## Part IV — Consensus and validator set (corrected to localnet reality)

### IV.1 Current reality: localnet / LiteSVM, not a deployed cluster

The current system runs on **localnet and the in-memory LiteSVM (Surfpool)
provider**, selected by `SOLANA_NETWORK=simnet`. There is **no deployed 7-node
consortium cluster**; consensus behaviour is the stock Solana client's. The
7-node topology, stake distribution, and consortium consensus are **designed and
discussed**, not deployed or measured. We do not claim a running consortium
chain.

### IV.2 Designed topology (for the deployment that the simulation models)

7 nodes (EGAT×2, MEA×2, PEA×2, ERC×1 observer, stake 0), giving f = 2 under
Tower BFT (n ≥ 3f+1; 2f+1 = 5 votes). EGAT stake < ⅓; distinct regions per org;
client diversity for nominal f = 2. **All (designed).**

### IV.3 Consensus is inherited, and conceded honestly

Tower BFT is inherited from the Solana client, chosen for ecosystem reasons
(Switchboard TEE, Token-2022, existing code), not consensus superiority; QBFT/
Fabric BFT fit a small consortium better on consensus alone. Tower BFT has no
native stake slashing and is being replaced by Alpenglow (late 2026). These are
limitations of the *modelled* deployment, stated so the simulation is not
mistaken for a finished system.

---

## Part V — Penalty model (designed, asymmetric)

State validators (EGAT/MEA/PEA): governance removal + audit record, **no stake
slash** (lawful/political reality for state enterprises). Private actors /
oracle / meter: **bond slash** by program logic + KYC freeze. Enforced on-chain
by whether a bond PDA exists. Validator removal is an on-chain *authorization*;
execution is off-chain ops. **All (designed/extension).**

---

## Part VI — Validation (simulation, honest scope)

Validation against the published CINELDI 80-bus rural feeder (Engan et al.,
*Data in Brief* 2025; CC BY 4.0), for solver and pipeline validation only.

- **Experiment 1 — ground-truth reproduction (validation):** bare feeder, real
  2021 load, noise disabled, compare computed extremes to published statistics
  (lowest voltage 0.854 p.u.; mean demand 8.17 MWh; mean peak 5.57 kWh/h).
  Establishes the solver is correct on a real feeder.
- **Experiment 2 — meter-to-mint fidelity (validation):** OBIS→mint on real
  load; verify 1 GRID = 1 kWh, idempotency, conservation, monotonicity. The four
  invariants on real data.
- **Experiment 3 — throughput (measurement):** λ_mint ≈ 5.33 mint·s⁻¹ on
  localnet; p99 latency, peak throughput, replay duration (fill from runs).
  Shows single-signer write-lock is the bottleneck — a simulation finding
  motivating the multi-signer pool.

**Validation/scenario boundary:** runs adding PV/EV/storage are *scenario
studies* (no ground truth), never reported as validated. **Threats to validity:**
Norwegian feeder (solver validation, not Thai representativeness);
co-simulation, not state estimation; determinism requires noise off/fixed seed.

We describe the backend as a **topology-aware AMI co-simulation testbed**, not a
digital twin (no Level-3 state estimation).

---

## Part VII — Build sequence

1. Close foundation gaps (hash-chained audit log; instruction-level policy;
   pre-sign sim default-on).
2. Harden oracle integrity (TEE + Merkle); name meter-level boundary as future
   work.
3. Refactor Rail A (energy + REC) onto the closed foundation; idempotency
   explicit.
4. Multi-signer fee-payer pool (removes ≈ 5.33 mint/s single-signer bottleneck).
5. Then Rail B (DR, record-only), Dual-Tracker, and the designed 7-node cluster.

---

## Part VIII — Paper-integrity checklist (anti-over-claim)

- **State simulation scope (Part 0) explicitly.** Never imply deployment,
  production-readiness, or live operation.
- **impl / sim / designed / extension tags** on every component claim.
- **Present tense only for (impl).** "We design / we simulate" for the rest.
- **Centerpiece = Rail A (energy + REC) settlement, demonstrated in simulation.**
  Oracle integrity is supporting; DR is future work; payment is simulated
  on-chain.
- **Ledger-only language.** Never "dispatch / control / command / actuate" for
  the chain. It clears, settles, records.
- **Concede the consensus point** (Tower BFT = ecosystem choice; localnet, not a
  deployed cluster).
- **Validation ≠ scenario.** Only ground-truth-backed results are "validated."
- **Consistency.** λ_mint ≈ 5.33, n = 7, f = 2 identical across abstract,
  design, figures.
- **Name the open boundary** (meter-level forgery) as the strongest future-work
  hook, not a hidden weakness.
- **No number without a run.** Every metric (latency, throughput, voltages) comes
  from an actual simulation run, never a placeholder presented as a result.

---

## Appendix A — what changed (v1 → v2 → v3)

**v3 unifies three documents:** master v2, the trade-settlement LA-adaptation
spec, and the chain-per-service/atomic-settlement spec. Part II.3 (trade adapts
into the LA layer), Part IIA (chain behaviour per service), and Appendix B
(escrow mechanism) were merged in. The v1→v2 changes below are retained.

**v3 update (policy + threat model):**

8. **Policy anchor (Part I.3):** GridTokenX mapped to the five national
   smart-grid pillars; Pillar 3 (Microgrid & Prosumer) is the primary anchor,
   Pillar 1 (DR) is platform-reuse.
9. **Oracle threat model corrected (Part III.2):** the real threat is
   single-custodian trust (MEA/PEA hold meter data by territory), not "the meter
   lies." The layer makes data verifiable without trusting the custodian alone —
   load-bearing for fair settlement, with meter-level attestation named as the
   future-work hook.

**v1 → v2:**

1. Framed as a **software simulation**, with an explicit scope statement (Part 0).
2. **Settlement trust** is the justification axis (Part I), stated up front, with
   honest concessions on where blockchain is unnecessary.
3. **GRID = clearing asset**, not a data record (Part II.1).
4. **Oracle integrity demoted to supporting** (Part III.2); settlement is the
   headline.
5. **DR reframed** as platform-reuse, not blockchain-necessity (Part III.5).
6. **Consensus/cluster corrected to localnet reality** (Part IV.1) — no claimed
   running consortium.
7. **CINELDI validation linked** to the energy rail with an explicit
   validation/scenario boundary (Part VI).

---

## Appendix B — Atomic settlement: the escrow mechanism

The trade service's trustless property rests entirely on the atomic swap. This
section specifies it at the instruction level. *(Simulated on localnet; the
mechanism is the contribution, not a deployment claim.)*

## 2.1 The problem it solves

Two peers who do not trust each other must exchange GRID for payment such that
**neither can take the other's asset without giving up their own.** A naive
two-transaction exchange (seller sends GRID, buyer sends payment) fails: whoever
moves second can defect. A trusted intermediary holding both sides also fails the
trust model (and would make the LA a custodian/reseller). The escrow makes the
exchange a single atomic state transition.

## 2.2 Escrow lifecycle (three instructions)

```
PDA: escrow = [b"escrow", trade_id]
     holds: seller_grid_amount, buyer_payment_amount, seller, buyer, state

ix 1: open_escrow(trade_id, grid_amount, payment_amount)
  - signer: matched seller AND buyer (or the cleared order proves both)
  - moves seller's GRID  → escrow PDA (program-owned, neither peer controls)
  - moves buyer's payment → escrow PDA
  - state = FUNDED only when BOTH legs are present
  - require!(both legs funded) else the instruction leaves nothing half-done

ix 2: settle_escrow(trade_id)
  - precondition: state == FUNDED (both legs in escrow)
  - atomic within one instruction:
        escrow.GRID    → buyer
        escrow.payment → seller
  - state = SETTLED
  - either the whole instruction succeeds or it reverts; no partial settle

ix 3: cancel_escrow(trade_id)
  - only if state == FUNDED and a timeout/abort condition holds
  - returns each leg to its original owner; state = CANCELLED
  - guarantees no peer is left without either their asset or their funds
```

## 2.3 Why this is atomic (the key point)

Atomicity comes from Solana's transaction model: an instruction either completes
fully or the entire transaction reverts and no account changes persist. In
`settle_escrow`, both transfers are in **one instruction**; there is no execution
state in which GRID has moved to the buyer but payment has not reached the
seller. The escrow PDA is **program-owned** between funding and settlement, so
neither peer—nor the LA—can withdraw unilaterally. The LA operates the matching
that produces `trade_id` but is not a signer on the escrow, so it cannot divert
either leg.

## 2.4 Invariants the escrow must enforce

| Invariant | Enforcement |
|---|---|
| No half-settlement | both transfers in one instruction; revert-on-failure |
| No unilateral withdrawal | escrow PDA program-owned; peers cannot sign its outflow |
| LA non-custody | LA key absent from escrow signer set |
| Conservation | settled GRID = escrowed GRID; settled payment = escrowed payment |
| No double-settle | state machine FUNDED → SETTLED is one-way; re-call is a no-op |
| Refund safety | cancel returns exact original legs; no value created or destroyed |

## 2.5 Honest boundaries

- **Simulated payment.** The "payment" leg is a simulated on-chain token swap.
  A real deployment would likely settle fiat off-chain through billing; the
  simulation models on-chain payment to demonstrate the atomic property.
- **Escrow ≠ price discovery.** The escrow settles a *matched* trade; fair
  matching/clearing is the order book's job, not the escrow's.
- **Token-2022 caveat.** If the design needs both confidential transfers and
  transfer hooks on the settlement token, recall these do not currently compose
  on Token-2022 — choose one, or document the limitation.

## 2.6 Why DR has no equivalent

The DR service has no escrow because there is nothing to swap atomically: the
state fund pays the participant, one-directionally, off-chain. There is no
counterparty asset to hold against, no defection risk, and therefore no need for
the trustless mechanism. The absence of escrow in DR is not a gap — it is the
correct consequence of DR having no settlement-trust problem.

---

