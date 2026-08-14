// =============================================================================
// template-uec.typ
// UEC ASEAN Workshop 2026 — Extended Abstract Template (Typst port)
// Converted from: UEC_Workshop_template_Word.docx
//
// Spec:
//   - Paper: A4 (210 x 297 mm)
//   - Margins: top 1.97cm, bottom 2.22cm, left 2.00cm, right 1.75cm
//   - Body font: Times New Roman 10pt, single line spacing
//   - Single column, max 2 pages, IEEE-style numbered references
//   - Figure captions BELOW; table captions ABOVE
//   - Equations centred, numbered (n) right margin
//   - Section headings: bold, numbered "1." / "3.1."
// =============================================================================

#let uec-abstract(
  title:         none,
  authors:       (),   // (name: "…", affil: 1)
  affiliations:  (),   // ("Faculty…", "Graduate School…")
  contact-email: none,
  body,
) = {

  // ── Page: A4, asymmetric margins from .docx DXA values ──────
  set page(
    paper:     "a4",
    margin:    (top: 1.97cm, bottom: 2.22cm, left: 2.00cm, right: 1.75cm),
    numbering: none,
  )

  // ── Base typography: Times New Roman 10pt ───────────────────
  set text(font: "Times New Roman", size: 10pt, lang: "en")
  // leading/spacing tightened (0.55em/0.9em → 0.43em/0.50em → 0.39em/0.42em):
  // first to fit the four result tables, then again when the settle
  // before/after was re-measured and its account grew; still looser than the
  // template's Word "single line spacing".
  set par(justify: true, leading: 0.39em, spacing: 0.42em)

  // ── Heading numbering scheme: "1." / "1.1." ─────────────────
  set heading(numbering: "1.1.")

  // Headings stay with the text they introduce — otherwise a section title can
  // be left stranded alone at the foot of a page.
  show heading: set block(sticky: true)

  // ── Heading appearance: BOLD, correct size ──────────────────
  // Level 1 → 11pt bold  (e.g. "1. Introduction")
  // Level 2 → 10pt bold  (e.g. "3.1. Equations and Data")
  // Headings marked `numbering: none` (Conclusion, Acknowledgment, References)
  // must not print a number — guard the counter display.
  show heading.where(level: 1): it => {
    v(0.32em, weak: true)
    // `sticky` must sit on the block this rule emits — the outer `set block`
    // never reaches it, so without this a section title can strand alone at
    // the foot of a page.
    block(sticky: true, text(
      size:   11pt,
      weight: "bold",
    )[#if it.numbering != none [#counter(heading).display("1.") ]#it.body])
    v(0.22em, weak: true)
  }

  show heading.where(level: 2): it => {
    v(0.3em, weak: true)
    text(
      size:   11pt,
      weight: "bold",
    )[#if it.numbering != none [#counter(heading).display("1.1.") ]#it.body]
    v(0.22em, weak: true)
  }

  // ── Equations: block, centred, numbered (n) right margin ────
  set math.equation(numbering: "(1)", block: true, supplement: none)
  // Display equations sit tighter than a paragraph break, to hold 2 pages.
  show math.equation.where(block: true): set block(above: 0.45em, below: 0.45em)
  // Bare `@eq-…` refs would print "1"; render them as "Eq. (1)".
  show ref: it => {
    if it.element != none and it.element.func() == math.equation {
      link(it.target)[Eq. (#numbering("1", ..counter(math.equation).at(it.element.location())))]
    } else { it }
  }

  // ── Figures: caption BELOW ───────────────────────────────────
  show figure.where(kind: image): set figure.caption(position: bottom)

  // ── Tables: caption ABOVE ────────────────────────────────────
  show figure.where(kind: table): set figure.caption(position: top)

  // ── Caption style: 9pt, "Figure 1: …" / "Table 1: …" ───────
  set figure.caption(separator: ": ")
  show figure.caption: set text(size: 8pt)
  // Captions run full text width, so left-align: a centred second line reads
  // as a stray fragment once a caption wraps.
  show figure.caption: set align(left)
  set figure(numbering: "1")

  // ── Figure/table spacing ─────────────────────────────────────
  // Tightened again (3pt → 2pt) when the fourth result table (fleet-size CU)
  // was added; four tables at 3pt pushed the references onto a third page.
  set figure(gap: 2pt)
  show figure: set block(above: 2pt, below: 2pt)

  // ── Bibliography: IEEE numeric, heading unnumbered ───────────
  set bibliography(style: "ieee", title: "References")
  show bibliography: set heading(numbering: none)
  show bibliography: set text(size: 6.0pt)
  show bibliography: set par(leading: 0.16em, spacing: 0.18em)

  // ── Title block ──────────────────────────────────────────────
  align(center)[
    #block(text(size: 14pt, weight: "bold")[#title])
    #v(0.4em)
    #block(text(size: 11pt)[
      #authors.map(a => [#a.name#super[#str(a.affil)]]).join(", ", last: ", and ")
    ])
    #v(0.3em)
    #block(text(size: 9pt)[
      #for (i, aff) in affiliations.enumerate() [
        #super[#str(i + 1)]#aff#h(0.8em)
      ]
    ])
    #if contact-email != none [
      #v(0.2em)
      #block(text(size: 9pt)[
        *Contact Email:* #link("mailto:" + contact-email)[#emph(contact-email)]
      ])
    ]
  ]
  v(0.6em)

  // ── Body ─────────────────────────────────────────────────────
  body
}

#show: uec-abstract.with(
title: "Implementation of Peer-to-Peer Energy Trading via Solana Smart Contracts
in a Permissioned Environment",
authors: (
  (name: "Chanthawat Kiriyadee", affil: "1"),
  (name: "Suwannee Adsavakulchai", affil: "1*")
),
affiliations: (
  "Department of Computer Engineering and Artificial Intelligence, School of Engineering, University of the Thai Chamber of Commerce (UTCC), Bangkok, Thailand",
),
contact-email: "2410717302003@live4.utcc.ac.th, Suwannee_ads@utcc.ac.th"
)

// ── Ruled table: full 0.4pt grid, 7pt text ────────────────────────────
// One helper so the three result tables cannot drift apart on stroke,
// inset, or header emphasis.
#let tbl(columns: (), align: (), header: (), ..rows) = text(size: 6.8pt)[
  #table(
    columns: columns,
    align:   align,
    stroke:  0.4pt,
    inset:   1.5pt,
    table.header(..header.map(h => strong(h))),
    ..rows.pos(),
  )
]

// ── Abstract ───────────────────
// The growing adoption of renewable energy in Thailand has created participate with surplus generation capacity currently cannot engage in peer-to-peer (P2P), which MEA and PEA announce to buyback surplus energy totalling 500MWh from participate single price-rate 2.20THB/kWh and limitation 5kWh/participate.

// The adoption of the Thailand Power Development Plan (PDP 2026–2050), the national strategic framework for electricity generation and infrastructure targets a transition to at least 60% clean energy to achieve Net Zero greenhouse gas emissions by 2050.
// This article presents on-chain settlement layer for energy trading which transaction settlement executes on a Solana Permissioned Environments an settlement layer implemented as a modular Anchor smart-contract programs, and the consensus blocks finality driven by Solana Proof of History (PoH) Tower-BFT. Pricing mechanism incorporate continues double auction (CDA) matches the on-chain order-book in real time immediate trades with dynamic pricing.

// such as BESS reserved dispatch. Alongside the participates trade uniform price auction established a single clearing price over 15-minute time interval.
// consortium governance mapped to Thailand's grid operators. The application layer through Anchor smart contact program, consensus and finality Solana PoH/Tower-BFT engine, market design with hybrid a continuous double auction (CDA) matches the on-chain order book in real time immediate trades such as BESS reserve dispatch, uniform-price auction single clearing price over 15-minute.

// Thailand's Power Development Plan (PDP 2026-2050) mandates a transition to a minimum of 60% clean energy generation to fulfill the nation's carbon neutrality commitments. Achieving this target will necessitate a rapid proliferation of distributed rooftop solar prosumers. However, under the existing Enhanced Single Buyer model, these prosumers lack a direct mechanism for peer-to-peer (P2P) trading of surplus generation, resulting in the underutilization of distributed energy capacity.

Thailand's three state utilities — EGAT, MEA, and PEA — have pursued a National Energy Trading Platform (NETP) since 2017 for peer-to-peer (P2P) trading among rooftop-solar prosumers, but it remains in development, and the regulated buy-back affords prosumers no direct means of exchanging surplus within the local distribution grid.
This paper evaluates a settlement layer for that role: six modular Anchor programs on a permissioned Solana runtime in which every high-frequency write is routed to a per-entity program-derived account (PDA), so transactions of distinct entities hold disjoint write sets and are scheduled in parallel by the Sealevel engine, ordered by Proof-of-History @yakovenko2018solana.
We measure compute, throughput and latency together, and find that they are not bound by the same thing. Compute is $O(1)$ and never binds: the steady telemetry write costs an identical 13,538 compute units (CU) at every scale of a 2,500× sweep from 80 to 200,000 meters and against 671,160 resident PDAs, while confirmation latency stays flat at p50 1.1–1.6 s (p95 ≤ 3.0 s) with zero delivery loss over 1.34 M first-attempt sends. Throughput is instead *associated* with lock footprint: ordering every measured path by the shared write-locked state it touches spans three orders of magnitude where the CU column does not — yet controlled experiments do not confirm the association as causal. Restoring the pre-fix lock footprint (the parent `ZoneMarket` re-declared writable, one account flag) leaves settlement throughput statistically unchanged from one fee payer to eight, and a previously reported ≈0.6 TPS proves to be a serial-await harness artifact. At ≈120 k CU a settle exhausts the block compute budget before its locks bind, so the write-set lever is not visible below a multi-node scheduler.

= Introduction

Since 2017 Thailand's state utilities have pursued a National Energy Trading Platform (NETP) for P2P trading among rooftop-solar prosumers, implemented on a Tendermint-based consortium blockchain @netp2019report. This article presents a Solana-based architecture as an alternative execution layer, motivated by NETP's own evaluation, in which Tendermint outperformed both Ethereum and Hyperledger Fabric under throughput testing: that result suggests further gains from a runtime whose execution is parallel rather than sequential. Such evaluations report throughput and compute cost as though computation were the scaling axis. The contribution here is to separate the axes: partition all hot-path state per entity, then measure compute, throughput and latency independently, so what binds each can be named rather than assumed.

= The Per-Entity Partition

The settlement layer is six Anchor programs @anchor2024 (anchor-lang and anchor-spl 1.0.0) — *energy-token, governance, oracle, registry, trading,* and *treasury* — in Rust, compiled to SBF bytecode. Programs invoke one another through cross-program invocation (CPI), authority delegated to PDAs that sign without any private key. A PDA is the SHA-256 of its seed tuple, bump byte, program id and a domain-separation constant — accepted only if *not* a valid Ed25519 curve point, so no private key can exist and the owning program may sign as that address. A transaction declares in advance every account it touches and whether each is writable; the runtime locks per account, so two transactions with disjoint writable sets run on different cores and two writing one account serialise. @tab-pda gives the hot-path partition under that rule.

#figure(
  caption: [*Hot-path state partition.* Every high-frequency write targets its
  own program-derived account, so any two are Sealevel-parallelisable.],
  tbl(
    columns: (auto, auto, 1fr),
    align: (left + horizon, left + horizon, left + horizon),
    header: ([Hot path], [Account], [Seed tuple]),
    [meter telemetry], [`MeterState`], [`[b"meter", meter_id]` (32-byte id ceiling = the runtime's seed limit)],
    [order placement], [`Order`], [`[b"order", authority, order_id]`],
    [settlement replay guard], [`OrderNullifier`], [`[b"nullifier", user, order_id]`],
    [registration counters], [`RegistryShard` ×16], [`[b"registry_shard", shard_id]`, $"shard" = "key"[0] mod 16$],
  ),
) <tab-pda>

Two consequences follow. First, global accounts — config, totals — are read-only on hot paths and *deliberately stale*; periodic admin instructions fold per-entity state back into them. Second, derivation is itself a budget item: `find_program_address` searches the bump byte downward from 255, a hash plus a curve-decompression check per candidate. The programs store the winning bump and thereafter validate with a single `create_program_address` — *1,651 CU against 12,136* on the aggregation path, a 7.3× saving on pure addressing.

= Method

All experiments ran on one node (Apple M2, Agave 3.1.10) of a private `solana-test-validator` network, so they characterise SVM semantics — account locking and compute metering — not consensus or leader rotation @solana2019towerbft. Throughput is *client-observed confirmed goodput*: confirmed transactions per wall-clock second from burst start to last confirmation, covering the pipeline from client signing to confirmation visibility. Every non-confirmed transaction is attributed to one class — send-rejected (refused by the RPC node, no fee), guard-rejected (executed, failed a program check, fee paid and recorded on-chain), or expired — separating delivery loss from validation working as intended. Transactions are pre-signed against a cached blockhash and submitted raw without preflight or retry, then confirmed by bulk signature-status polling on a 1.5 s sweep under a 3,000-transaction in-flight window; latency is therefore poll-quantised (±1.5 s), an upper bound on the runtime's own cost rather than a measurement of it. CU is machine-independent, read post-hoc from transaction metadata.
The telemetry sweep submits one reading per meter from $N$ distinct meters over two epochs at least 61 s apart — the rate-limit and monotonic-timestamp guards force the gap — separating one-off PDA creation from the recurring steady write. It covers $N = 80$ to 200,000 (1.34 M transactions) over two runs, the second unreset between scales (@tab-fleet). The order-entry burst submits $N = 10^4$ orders over 16 round-robin zone shards.

= Results and Discussion

*Compute is $O(1)$ and never binds.* @tab-cu gives the instruction profile against the 200,000-CU default per-instruction budget; every control, telemetry and settlement-recording path costs at most ≈8% of it. @tab-fleet resolves the telemetry write by fleet size: with fixed-width meter identifiers the steady write is *13,538 CU in every cell of both runs* — 80 to 200,000 meters, a 2,500× range with zero drift — and the first write is likewise constant at 16,157 CU because it additionally initialises and rent-funds the PDA (one extra identifier byte costs ≈96 CU — the spread earlier variable-width measurements showed as 13,337–13,634). Above the mode sits a deterministic ladder in exact 1,500-CU steps, geometrically decaying: `find_program_address` pays one 1,500-CU curve check per bump candidate and ≈half of candidates fail, so half of all meters resolve at bump 255 and each further step halves — a per-meter constant, not noise. Settlement is the one expensive instruction at ≈121 k CU (≈61%), dominated by native Ed25519 verification and instruction-sysvar introspection authorising the trade, not by settlement arithmetic.

#figure(
  caption: [*Compute cost per instruction*, against the 200,000-CU default
  per-instruction budget. Machine-independent, read from transaction metadata;
  modes; PDA-deriving paths carry the bump ladder above the mode (see text).],
  tbl(
    columns: (1fr, auto, auto),
    align: (left + horizon, right + horizon, right + horizon),
    header: ([Instruction], [CU], [% of 200 k]),
    [`do_nothing` (dispatch + signature-verify floor)], [769], [0.4%],
    [`treasury.record_settlement`], [3,302], [1.7%],
    [`treasury.record_settlement_sharded`], [5,375], [2.7%],
    [`trading.submit_limit_order_sharded`], [9,808], [4.9%],
    [`oracle.submit_meter_reading` (steady)], [13,538], [6.8%],
    [`oracle.submit_meter_reading` (first, inits PDA)], [16,157], [8.1%],
    [`trading.settle_offchain_match`], [≈121 k], [≈61%],
  ),
) <tab-cu>

#figure(
  caption: [*Per-meter compute against fleet size.* Steady-state CU mode for
  `oracle.submit_meter_reading`, measured live, fixed-width meter ids. Run B
  continues run A's ledger without a reset, so its scales write against
  161,160–471,160 already-resident PDAs and it ends holding 671,160. Every cell
  identical — the table #emph[is] the $O(1)$ result.],
  tbl(
    columns: (auto, 1fr, 1fr, 1fr, 1fr, 1fr, 1fr, 1fr),
    align: (left + horizon, right + horizon, right + horizon, right + horizon,
            right + horizon, right + horizon, right + horizon, right + horizon),
    header: ([Fleet size $N$ (meters)], [80], [1,000], [10,000], [50,000],
             [100,000], [150,000], [200,000]),
    [Steady write, run A (CU)], [13,538], [13,538], [13,538], [13,538], [13,538], [—], [—],
    [Steady write, run B (CU)], [—], [—], [13,538], [13,538], [13,538], [13,538], [13,538],
  ),
) <tab-fleet>

*Compute is also $O(1)$ in accumulated state:* run B's last 200,000 submissions cost the same against 471,160 resident accounts as the first scale's did against 161,160, and the ledger ends holding 671,160. The account store explains it: an update appends to an append-only file, and lookup goes through an in-memory pubkey → (slot, offset) index, so either write costs one probe and one append. What scales with account count — index memory, snapshot size, startup time — is a multi-node concern, invisible to per-transaction cost.

*Throughput orders by lock footprint, but the mechanism does not confirm.* @tab-tps sorts every measured path by the shared writable state it touches, and that ordering — not the CU column — tracks the rate across three orders of magnitude. The causal test fails. Anchor's `mut` imposes a writability *requirement*, not a prohibition, so the shipped binary accepts the pre-fix lock footprint when the client declares `ZoneMarket` writable — one `AccountMeta`, verified on the wire. Over five repeats of 1,200 settles, arm order alternating, the writable arm returns 493 against 561 confirmed settles·s#super[−1] across eight fee payers and 447 against 446 across one. Even the shared fee-payer lock does not move throughput: conflicting transactions still land within one slot as successive entries, so a write lock costs wall-clock drain, not slot occupancy — and at ≈120 k CU per settle the block compute budget saturates before locks bind. We therefore withdraw the 2.7–3× previously attributed to deleting this `mut`; both original figures are accounted for: a session's first burst runs ≈5–6× slower than every later one (validator warm-up), and the ≈0.6 TPS once reported for single-payer settlement is a serial-await harness measuring its own round-trip (0.69 TPS, p50 463 ms reproduced). Order entry shares the caveat: the *cheaper* instruction returned 180 TPS against telemetry's 462 under a vestigial `mut` since dropped. Re-measured post-fix on the original 10#super[4] configuration, it lands all 10,000 orders at ≈1,000 TPS in every arm from one payer on one shard to 16 on 16 — a 5.7× spanning the fix, a rewritten harness and a warm validator, so none of it attributes to the lock. Telemetry, holding only the gateway fee payer, sustains 234–296 TPS from 10,000 to 150,000 meters with no monotone trend, dipping to 182 in the final 200,000-meter epoch: not proportional, since one payer signs everything, and largely scale-independent, since per-meter PDAs never contend.

#figure(
  caption: [*Throughput by lock footprint.* Paths ordered by the shared
  write-locked state they touch — an ordering, not a demonstrated cause (see
  text). Harnesses differ per row; rows are not mutually comparable, and the closed-loop OLTP row is its own concurrency knob (TPS ≈ $c$/latency).
  #emph[pre-fix] = measured before the vestigial `mut` on `zone_market` was
  dropped.],
  tbl(
    columns: (1fr, auto, auto, auto),
    align: (left + horizon, right + horizon, right + horizon, left + horizon),
    header: ([Path], [CU], [TPS], [Shared writable state]),
    [RPC read (serial → 32 in flight)], [—], [731 → 6,321], [none — no consensus round-trip],
    [meter ingest (10 k–200 k meters)], [13,538], [182–296], [gateway fee payer],
    [order entry (10 k orders, pre-fix)], [9,884], [180], [fee payer + `zone_market`],
    [order entry (10 k orders, re-measured)], [9,808], [915–1,028], [fee payer + zone shard(s)],
    [OLTP proxy, closed loop ($c$ = 5 → 40)], [≈22.8 k], [10.4 → 78.4], [fee payer + per-district counters],
    [settlement, concurrent, 1–8 fee payers], [≈120 k], [446–561], [fee payer + `energy_mint` + collectors],
  ),
) <tab-tps>

*Latency is set by block time, not by the partition.* Confirmation holds p50 1.1–1.6 s and p95 ≤ 3.0 s across the whole 2,500× fleet range — flat where a contended design would degrade — and order entry sits at p50 2,173 ms, p95 3,565 ms (measured pre-fix). Both are send→first-seen-confirmed upper bounds dominated by the ≈400–600 ms single-node block time, not measurements of runtime cost — visible in the read path, which needs no consensus round-trip and answers in ≈1.4 ms client-observed, HTTP transport included. *Delivery loss is zero* across all 1.34 M first-attempt sends of the two sweeps — none refused at the RPC, none expired unconfirmed; the 0.47% residue is a deterministic anomaly-gate probe firing on the same meter indices every epoch, each landing on-chain as a fee-paid guard rejection.

= Conclusion

With hot-path state partitioned per entity, neither computation nor per-entity contention bounds a P2P energy settlement layer: the steady write is $O(1)$ in fleet size and in resident account count, and latency is flat over a 2,500× sweep. Lock footprint orders the measured paths more closely than instruction cost, but the ordering did not survive a controlled test as a mechanism: settlement throughput is unchanged from one fee payer to eight — at ≈120 k CU the settle exhausts the block compute budget before its locks bind — and the two strongest prior data points dissolve into validator warm-up and a serial-await harness. Shrinking declared write sets remains sound design; below a multi-node scheduler, a before/after on lock footprint chiefly measures its own harness. A single validator bounds execution and locking only; reproducing these results on a multi-validator consortium mapped to EGAT, MEA, and PEA would place both consensus and the scheduler under test, and suits UEC–ASEAN collaboration.

// The conclusion should highlight the main outcomes and suggest potential future
// work or collaboration opportunities between UEC and ASEAN partners.

#heading(numbering: none)[Acknowledgment]
The authors thank the University of the Thai Chamber of Commerce (UTCC) for institutional support, and the organizers, the UEC ASEAN Research Center (UARC) and Multimedia University (MMU), for hosting this workshop.
// =============================================================================
//  REFERENCES
//  Option A (used here): inline bib database via `bibliography()` below.
//  Option B: keep a separate refs.bib and point to it.
// =============================================================================

#bibliography(
  bytes("
    % --- Thailand energy policy: verified primary/official sources ---

    @misc{eppo_pdp2024,
      author       = {{Energy Policy and Planning Office (EPPO), Ministry of Energy, Thailand}},
      title        = {Draft {P}ower {D}evelopment {P}lan of {T}hailand 2024--2037 ({PDP2024}): Public Hearing Draft},
      year         = {2024},
      month        = jun,
      howpublished = {\url{https://www.eppo.go.th/}},
      note         = {Public consultation draft, 19--23 June 2024; new capacity and storage total
                      60{,}208~MW, of which 34{,}851~MW renewable; not yet approved by the
                      National Energy Policy Council as of early 2026},
    }

    @misc{eppo_smartgrid2025,
      author       = {Lawanstined, Duangtip},
      title        = {Thailand's Smart Grid Masterplan},
      howpublished = {Presented at Regional Energy Transition Dialogue 2025, organized by
                      CASE for SEA and GIZ},
      year         = {2025},
      month        = jul,
      note         = {Energy Policy and Planning Office (EPPO), Ministry of Energy, Thailand.
                      Describes the Smart Grid Action Plan (2022--2031), the medium-term
                      phase of the overarching Master Plan for Smart Grid Network System
                      Development in Thailand (2015--2036); confirms continuous AMI
                      rollout by MEA/PEA under Pillar~3 (Microgrid \& Prosumer
                      Administration)},
      url          = {https://caseforsea.org/wp-content/uploads/2025/07/570953108071907720_1.-CASE-Smart-grid-%E0%B8%AA%E0%B9%88%E0%B8%87-GIZ.pdf},
    }

    @techreport{onep_ltleds2022,
      author      = {{Office of Natural Resources and Environmental Policy and Planning (ONEP)}},
      title       = {Thailand's Long-Term Low Greenhouse Gas Emission Development
                     Strategy (Revised)},
      institution = {UNFCCC},
      year        = {2022},
      month       = nov,
      note        = {Submitted 7 November 2022 at COP27; states carbon neutrality
                     by 2050 and net-zero GHG emissions by 2065},
    }

    @misc{thailand_ndc3_2025,
      author       = {{Royal Thai Government}},
      title        = {Thailand's Third {N}ationally {D}etermined {C}ontribution ({NDC 3.0})},
      year         = {2025},
      month        = nov,
      howpublished = {Approved by Cabinet, 4 November 2025},
      note         = {Accelerates the net-zero target from 2065 to 2050; targets a
                      47\% reduction in net GHG emissions by 2035 relative to 2019},
    }

    @techreport{netp2019report,
      author       = {{Metropolitan Electricity Authority (MEA) and Electricity
                       Generating Authority of Thailand (EGAT) and Provincial
                       Electricity Authority (PEA)}},
      title        = {{Development of the National Energy Trading Platform (NETP)}:
                       Research and Development Project Report},
      institution  = {Submitted to the State Enterprise Policy Office (SEPO),
                      Thailand},
      year         = {2019},
      month        = dec,
      howpublished = {\url{https://thai-smartgrid.com/wp-content/uploads/2020/05/%E0%B8%A3%E0%B8%B2%E0%B8%A2%E0%B8%87%E0%B8%B2%E0%B8%99-NETP-%E0%B8%9B%E0%B8%B5-2561.pdf}},
      note         = {Full technical report of the NETP prototype (2018--2019
                      fiscal year). Evaluated Ethereum (15--30 TPS), Hyperledger
                      Fabric (300 TPS), EOS, and Tendermint (2{,}002.8 TPS,
                      highest-scoring) as candidate platforms; selected a
                      5-node permissioned Consortium Blockchain on Tendermint
                      (3 utility nodes + 2 regulatory nodes) with PBFT-style
                      Propose/Prevote/Precommit/Commit voting requiring 2/3
                      majority. Piloted bilateral P2P settlement only across
                      EGAT/MEA/PEA facilities (Apr--Oct 2019) with hourly
                      (60-minute) smart-meter reporting; market-based auction
                      clearing was explicitly out of scope for this phase},
    }

    @misc{egat_netp,
      author       = {{Electricity Generating Authority of Thailand (EGAT)}},
      title        = {National {E}nergy {T}rading {P}latform},
      howpublished = {\url{https://www.egat.co.th/home/en/national-energy-trading-platform/}},
      note         = {Joint initiative of EGAT, MEA, and PEA (Thailand's three state
                      utilities), initiated circa 2017 to develop a national P2P
                      energy trading platform for rooftop-solar prosumers;
                      envisions blockchain-based settlement with a dedicated
                      digital currency. Reported as still under development as of
                      2025 (see governance literature)},
    }

    @misc{pea_solar_prachachon_2026,
    author       = {{Provincial Electricity Authority (PEA), Thailand}},
    title        = {{Rooftop Solar Power Generation Project for Residential
                     Prosumers (Solar Phak Prachachon)}: Application Period
                     from 2026 ({VSPP-RT3-2})},
    year         = {2026},
    howpublished = {\url{https://ppim.pea.co.th/app/v1/project/solar/detail/6a3df059ee9f0e286c0a1766}},
    note         = {Regulatory basis: Energy Regulatory Commission (ERC)
                    announcement inviting rooftop-solar purchase bids for
                    residential prosumers, B.E. 2569 (2026). Fixed buy-back
                    rate 2.20 THB/kWh for surplus generation over a 10-year
                    term; capped at 5 kW (AC) capacity per participant and
                    500 MW (AC) aggregate capacity jointly administered by
                    PEA and MEA; self-consumption prioritised, with only
                    surplus eligible for purchase},
    }

    % --- Reference platforms and prior work ---
     @dataset{cineldi2024,
      author       = {Engan, Lill Mari and Ekrheim, Stine and Bjarghov, Sigurd
                      and Klemets, Jonatan and Kjølle, Gerd and Schytte, Ivan},
      title        = {Reference dataset for semi-urban and rural {N}orwegian
                       low voltage distribution system},
      year         = {2024},
      month        = dec,
      publisher    = {Zenodo},
      doi          = {10.5281/zenodo.14528192},
      note         = {Developed within the Norwegian CINELDI research centre
                      (SINTEF Energy Research). Four anonymised radial LV grids
                      at 230 V (39/56-bus semi-urban, 50/80-bus rural) in
                      MATPOWER format, with hourly active/reactive load per
                      bus; no distributed generation data included. This work
                      imports the 80-bus rural grid topology into
                      `pandapower`; time-series generation is synthetic (see
                      Methodology)},
    }
    @article{mengelkamp2018,
      author  = {Mengelkamp, Esther and Gärttner, Johannes and Rock, Kerstin
                 and Kessler, Scott and Orsini, Lawrence and Weinhardt, Christof},
      title   = {Designing microgrid energy markets: {A} case study:
                 {The} {Brooklyn} {Microgrid}},
      journal = {Applied Energy},
      volume  = {210},
      pages   = {870--880},
      year    = {2018},
    }

    @article{thurner2018,
      author  = {Thurner, Leon and Scheidler, Alexander and Schäfer, Florian
                 and Menke, Jan-Hendrik and Dollichon, Julian and Meier, Friederike
                 and Meinecke, Steffen and Braun, Martin},
      title   = {pandapower---{An} Open-Source {Python} Tool for Convenient Modeling,
                 Analysis, and Optimization of Electric Power Systems},
      journal = {IEEE Transactions on Power Systems},
      volume  = {33},
      number  = {6},
      pages   = {6510--6521},
      year    = {2018},
    }

    % --- Solana technical references ---

    @misc{yakovenko2018solana,
      author       = {Yakovenko, Anatoly},
      title        = {Solana: {A} New Architecture for a High Performance Blockchain
                      v0.8.13},
      year         = {2018},
      howpublished = {\url{https://solana.com/solana-whitepaper.pdf}},
      note         = {Defines Proof-of-History (PoH) as a verifiable-delay-function
                      clock for transaction ordering, used alongside a separate
                      consensus algorithm},
    }

    @misc{solana2019towerbft,
      author       = {{Solana Foundation}},
      title        = {Tower {BFT}: {S}olana's High Performance Implementation of {PBFT}},
      year         = {2019},
      month        = jul,
      howpublished = {\url{https://solana.com/news/tower-bft--solana-s-high-performance-implementation-of-pbft}},
      note         = {Describes Tower BFT, Solana's PoS-based consensus protocol,
                      distinct from the PoH clock},
    }

    @article{holmgren2018pvlib,
      author  = {Holmgren, William F. and Hansen, Clifford W. and Mikofski, Mark A.},
      title   = {pvlib python: {A} python package for modeling solar energy systems},
      journal = {Journal of Open Source Software},
      volume  = {3},
      number  = {29},
      pages   = {884},
      year    = {2018},
      doi     = {10.21105/joss.00884},
    }

    @misc{anchor2024,
      author = {{Coral / Anchor contributors}},
      title  = {Anchor: Solana's {Sealevel} runtime framework},
      howpublished = {Online documentation},
      year   = {2024},
      url    = {https://www.anchor-lang.com/}
    }
  "),
  title: "References",
)
