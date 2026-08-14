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
//   - Acknowledgment + References are UNNUMBERED (use `heading(numbering: none)`)
//   - Section titles must describe their own content, not the template's examples
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
  set par(justify: true, leading: 0.44em, spacing: 0.55em)

  // ── Heading numbering scheme: "1." / "1.1." ─────────────────
  set heading(numbering: "1.1.")

  // ── Heading appearance: BOLD, correct size ──────────────────
  // Level 1 → 11pt bold  (e.g. "1. Introduction")
  // Level 2 → 10pt bold  (e.g. "3.1. Community-Month Dataset …")
  // A heading created with `numbering: none` prints no number (Acknowledgment).
  show heading.where(level: 1): it => {
    v(1.0em, weak: true)
    text(
      size:   11pt,
      weight: "bold",
    )[#if it.numbering != none [#counter(heading).display("1.") ]#it.body]
    v(0.4em, weak: true)
  }

  show heading.where(level: 2): it => {
    v(0.7em, weak: true)
    text(
      size:   11pt,
      weight: "bold",
    )[#if it.numbering != none [#counter(heading).display("1.1.") ]#it.body]
    v(0.3em, weak: true)
  }

  // ── Equations: block, centred, numbered (n) right margin ────
  set math.equation(numbering: "(1)", block: true, supplement: none)

  // ── Figures: caption BELOW ───────────────────────────────────
  show figure.where(kind: image): set figure.caption(position: bottom)

  // ── Tables: caption ABOVE ────────────────────────────────────
  show figure.where(kind: table): set figure.caption(position: top)

  // ── Caption style: 9pt, "Figure 1: …" / "Table 1: …" ───────
  set figure.caption(separator: ": ")
  show figure.caption: set text(size: 9pt)
  set figure(numbering: "1")

  // ── Figure/table spacing ─────────────────────────────────────
  set figure(gap: 4pt)
  show figure: set block(above: 6pt, below: 6pt)

  // ── Bibliography: IEEE numeric, heading unnumbered ───────────
  set bibliography(style: "ieee", title: "References")
  show bibliography: set heading(numbering: none)
  show bibliography: set text(size: 8pt)
  show bibliography: set par(leading: 0.3em, spacing: 0.35em)

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

// ── Abstract ───────────────────
// The growing adoption of renewable energy in Thailand has created participate with surplus generation capacity currently cannot engage in peer-to-peer (P2P), which MEA and PEA announce to buyback surplus energy totalling 500MWh from participate single price-rate 2.20THB/kWh and limitation 5kWh/participate.

// The adoption of the Thailand Power Development Plan (PDP 2026–2050), the national strategic framework for electricity generation and infrastructure targets a transition to at least 60% clean energy to achieve Net Zero greenhouse gas emissions by 2050.
// This article presents on-chain settlement layer for energy trading which transaction settlement executes on a Solana Permissioned Environments an settlement layer implemented as a modular Anchor smart-contract programs, and the consensus blocks finality driven by Solana Proof of History (PoH) Tower-BFT. Pricing mechanism incorporate continues double auction (CDA) matches the on-chain order-book in real time immediate trades with dynamic pricing.

// such as BESS reserved dispatch. Alongside the participates trade uniform price auction established a single clearing price over 15-minute time interval.
// consortium governance mapped to Thailand's grid operators. The application layer through Anchor smart contact program, consensus and finality Solana PoH/Tower-BFT engine, market design with hybrid a continuous double auction (CDA) matches the on-chain order book in real time immediate trades such as BESS reserve dispatch, uniform-price auction single clearing price over 15-minute.

// Thailand's Power Development Plan (PDP 2026-2050) mandates a transition to a minimum of 60% clean energy generation to fulfill the nation's carbon neutrality commitments. Achieving this target will necessitate a rapid proliferation of distributed rooftop solar prosumers. However, under the existing Enhanced Single Buyer model, these prosumers lack a direct mechanism for peer-to-peer (P2P) trading of surplus generation, resulting in the underutilization of distributed energy capacity.

Thailand's three state utilities EGAT, MEA, and PEA have advanced a National Energy Trading Platform (NETP) since 2017 to facilitate Peer-to-Peer (P2P) trading among rooftop-solar prosumers, envisaging a blockchain-based settlement layer with a dedicated digital currency. However, remains in development, and Thailand's regulated buy-back scheme still provides no direct mechanism for prosumers to exchange surplus generation within the local electrical grid.
This paper presents a smart-contract-based on-chain settlement layer for P2P energy trading, realized as five modular Anchor programs deployed on a permissioned Solana runtime that utilize the Sealevel parallel-execution engine. By routing every high-frequency write to a per-entity program-derived account (PDA), the system permits transactions with disjoint write sets to execute in parallel, with transaction ordering provided by Solana's Proof-of-History (PoH). The evaluate market clearing price framework couples a continuous double auction (CDA) for real-time trades with a uniform-price auction that clears aggregated prosumer bids into a single settlement price over fifteen-minute epochs.
We simulate energy consumption, generation, and power flow for a network of $M$ meters over $D$ days at fifteen-minute intervals within a low-voltage grid topology, of which 15% of meters are prosumers. The full token life-cycle minting, settlement, and burning is evaluated on a single-node validator (Apple M2, Agave 3.1.10). We report the resulting throughput, energy-conservation, and net-revenue outcomes, each independently re-derived and audited from on-chain state.

= Introduction

Since 2017 Thailand's state utilities have pursued a National Energy Trading Platform (NETP) for P2P trading among rooftop-solar prosumers, implemented on a Tendermint-based consortium blockchain @netp2019report. This article presents a Solana-based architecture as an alternative execution layer, motivated by NETP's own evaluation, in which Tendermint outperformed both Ethereum and Hyperledger Fabric under throughput testing: that result suggests further gains from a runtime whose execution is parallel rather than sequential.
Such evaluations report throughput and compute cost as though computation were the axis along which a settlement layer scales. The contribution here is to separate the axes — partition all hot-path state per entity, then measure compute, throughput and latency independently, so that what binds each can be named rather than assumed — and then, in a second and separate experiment, to confirm that the market built on that partition settles correctly and profitably against audited on-chain state.

= The Per-Entity Partition and Measurement Method

#set list(spacing: 0.5em, indent: 0.6em, body-indent: 0.4em)
- *Smart-contract layer.* The settlement layer comprises Smart Contract programs @anchor2024 (anchor-lang and anchor-spl 1.0.0), written in Rust and compiled to SBF bytecode for the Solana Virtual Machine, in which programs invoke one another through cross-program invocation (CPI), with authority delegated to PDAs that sign without any private key existing.
- *Per-entity partition.* A transaction declares in advance every account it touches and whether each is writable, and the runtime locks per account, so that two transactions with disjoint writable sets execute on different cores whereas two writing one account serialise. Every high-frequency write therefore targets its own PDA — `MeterState` per meter, `Order` per order, `OrderNullifier` per settlement replay guard, and registration counters sharded sixteen ways — while global accounts such as configuration and running totals remain read-only on hot paths and deliberately stale, folded forward by periodic administrative instructions.
- *Environment.* Both experiments were conducted on a single node (Apple M2, Agave 3.1.10) of a private `solana-test-validator` network, so that they characterise SVM semantics — account locking and compute metering — rather than consensus or leader rotation @solana2019towerbft.
- *Metric.* Throughput is reported as client-observed confirmed goodput, defined as confirmed transactions per wall-clock second from burst start to last confirmation, and every non-confirmed transaction is attributed to one of three classes — send-rejected, guard-rejected, or expired — which separates delivery loss from validation operating as intended.
- *Experiment A (scaling sweep).* One reading per meter is submitted from $N$ distinct meters over two epochs at least 61 s apart, covering $N = 80$ to 200,000 (1.35 M transactions).
- *Experiment B (community-month replay).* The full token life-cycle — minting, settlement, and burning — is driven over the month of @tab-data, on a topology taken from the CINELDI 80-bus rural LV reference grid @cineldi2024 and resolved with pandapower @thurner2018, with time-series produced by the simulator under a fixed seed and solar modelled via pvlib @holmgren2018pvlib.

The two experiments use different harnesses; their rates are therefore not mutually comparable.

= Primary Result: Throughput Orders by Lock Footprint

*Compute is $O(1)$ and never binds.* In Experiment A the steady telemetry write costs an identical 13,538 CU at every scale from 80 to 200,000 meters — a 2,500× range with zero drift, fixed-width meter ids — against a 200,000-CU default per-instruction budget, and the final submissions cost the same against 471,160 resident PDAs as the first scale did against 161,160 (the ledger ends holding 671,160). The first write for a meter costs 16,157 CU, because it initialises and rent-funds the PDA; above the mode sits a deterministic 1,500-CU-per-step bump-search ladder (`find_program_address` pays one curve check per candidate, geometric across meters). Latency is likewise flat, p50 1.1–1.6 s and p95 ≤ 3.0 s across the whole sweep, where a contended design would degrade; delivery loss is zero across 1.34 M first-attempt sends.

*Throughput orders by lock footprint, but the mechanism does not confirm.* @tab-tps sorts every measured path by the shared writable state it touches, and that ordering — not the CU column — tracks the rate across three orders of magnitude. The association is strong; the causal test fails. Anchor's `mut` imposes a writability requirement, not a prohibition, so the shipped binary still accepts the pre-fix lock footprint if the client declares `ZoneMarket` writable — one `AccountMeta`, nothing else changed. Over five repeats of 1,200 settles, the writable arm returns 493 against 561 confirmed settles·s#super[−1] across eight fee payers (overlapping ranges), and 447 against 446 across one: even the shared fee-payer lock does not move throughput, because conflicting transactions still land within a slot through successive entries, and at ≈120 k CU per settle the block compute budget saturates before locks bind. We therefore withdraw the 2.7–3× previously attributed to deleting this `mut`; a previously reported ≈0.6 TPS for single-payer settlement reproduces exactly (0.69 TPS, p50 463 ms per settle) when the harness awaits each confirmation before the next send — a measurement-loop property, since the same path sustains ≈450 TPS with transactions concurrently in flight. Order entry carries the same caveat: the *cheaper* instruction returned 180 TPS against telemetry's 462 while its context declared the shared zone-market account writable. Re-measured post-fix on the original 10#super[4] configuration, the path lands all 10,000 orders at ≈1,000 TPS in every arm from one payer on one shard to 16 on 16 — a 5.7× that spans the fix, a rewritten harness and a warm validator, so no share of it attributes to the lock.

#figure(
  caption: [*Throughput by lock footprint* (Experiment A). Paths ordered by the
  shared write-locked state they touch — an ordering, not a demonstrated cause
  (see text). Harnesses differ per row; rows are not mutually comparable, and the closed-loop OLTP row is its own concurrency knob (TPS ≈ $c$/latency).],
  kind: table,
  supplement: [Table],
  text(size: 7pt)[
    #table(
      columns: (auto, auto, auto, auto),
      align: (left + horizon, right + horizon, right + horizon, left + horizon),
      stroke: 0.4pt,
      inset: 2pt,
      table.header([*Path*], [*CU*], [*TPS*], [*Shared writable state*]),
      [RPC read (serial → 32 in flight)], [—], [731 → 6,321], [none — no consensus round-trip],
      [meter ingest (10 k–200 k meters)], [13,538], [182–296], [gateway fee payer],
      [order entry (10 k orders, pre-fix)], [9,884], [180], [fee payer + `zone_market`],
      [order entry (10 k orders, re-measured)], [9,808], [915–1,028], [fee payer + zone shard(s)],
      [OLTP proxy, closed loop ($c$ = 5 → 40)], [≈22.8 k], [10.4 → 78.4], [fee payer + per-district counters],
      [settlement, awaited serially (harness-bound)], [≈115 k], [≈0.6], [— (one block-time RTT per settle)],
      [settlement, concurrent, 1–8 fee payers], [≈120 k], [446–561], [fee payer + `energy_mint` + collectors],
    )
  ],
) <tab-tps>

== Secondary Result: Audited Community-Month Settlement

Experiment B replays the month of @tab-data in 1,008.7 s (2,570× real time) with zero delivery loss; all 57 rejected readings are deterministic anomaly-gate rejections, predicted offline from the same 10× rule and matched exactly on chain. Under this harness telemetry sustains ≈303 readings·s#super[−1] and each Ed25519-verified settlement costs ≈117 k CU (p50 of all 120 fills). The energy-closure identities hold bigint-exact on chain — 16 of 16 audit assertions, from minted surplus through burned settlement to collector balances — and net revenue across the three price rules orders uniform 2.290 > buy-back 2.200 > CDA 2.065 THB/kWh, so wheeling policy sets the P2P participation threshold.

#figure(
  caption: [*The simulated community-month dataset* (Experiment B;
  seed-deterministic, no field data).],
  kind: table,
  supplement: [Table],
  text(size: 7pt)[
    #table(
      columns: (auto, auto),
      align: (left + horizon, left + horizon),
      stroke: 0.4pt,
      inset: 2pt,
      table.header([*Quantity*], [*Value*]),
      [fleet], [80 meters: 12 prosumer sellers, 68 consumers],
      [market policy], [sell cap $C = 10$ kWh/day per prosumer; 0.1 kWh dust floor],
      [horizon / readings], [30 days × 96 ticks ($Delta t$ = 15 min) = 230,400 readings, integer Wh],
      [month energy], [15,868.5 kWh generated; 144,879.8 kWh consumed; 10,386.7 kWh interval surplus],
      [oracle-accepted surplus], [8,253.502 kWh; 919 readings gate-rejected],
    )
  ],
) <tab-data>

= Conclusion

Over the range measured here, partitioning hot-path state per entity leaves neither computation nor per-entity contention as the binding constraint: the steady write is an identical 13,538 CU from 80 to 200,000 meters and against 671,160 resident accounts, and confirmation latency does not degrade across that sweep. What orders the measured paths is lock footprint on the few genuinely shared accounts, more closely than instruction cost does — but that ordering did not survive a controlled test as a mechanism: with the pre-fix lock footprint reproduced on the shipped binary, settlement throughput is unchanged from one fee payer to eight, and the two strongest prior data points dissolve under re-measurement, one into validator warm-up, one into a harness that awaited each settle's confirmation before sending the next. Shrinking declared write sets remains sound design; on a single node it buys nothing measurable here — order entry, re-measured post-fix, lands identically from one payer on one shard to 16 on 16. The community-month replay is a seeded simulation rather than field data, and within it the energy-closure identities held in all 15 audit assertions and P2P net revenue under uniform-price clearing exceeded the regulated buy-back rate. These results characterise one implementation on a single validator, which bounds execution and locking only; reproducing them on a multi-validator consortium of the form NETP itself prototyped across EGAT, MEA, and PEA @netp2019report would place consensus under test, and suits UEC–ASEAN collaboration.

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
      howpublished = {\\url{https://www.eppo.go.th/}},
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
                      rollout by MEA/PEA under Pillar~3 (Microgrid \\& Prosumer
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
                      47\\% reduction in net GHG emissions by 2035 relative to 2019},
    }

    @techreport{netp2019report,
      author       = {{Metropolitan Electricity Authority (MEA) and Electricity
                       Generating Authority of Thailand (EGAT) and Provincial
                       Electricity Authority (PEA)}},
      title        = {{Development of the National Energy Trading Platform (NETP)}:
                       Research and Development Project Report and Digital
                       Platform Roadmap for Thailand's Electricity Authorities},
      institution  = {Submitted to the State Enterprise Policy Office (SEPO),
                      Thailand},
      year         = {2019},
      month        = dec,
      howpublished = {\\url{https://thai-smartgrid.com/wp-content/uploads/2020/05/%E0%B8%A3%E0%B8%B2%E0%B8%A2%E0%B8%87%E0%B8%B2%E0%B8%99-NETP-%E0%B8%9B%E0%B8%B5-2561.pdf}},
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
      howpublished = {\\url{https://www.egat.co.th/home/en/national-energy-trading-platform/}},
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
    howpublished = {\\url{https://ppim.pea.co.th/app/v1/project/solar/detail/6a3df059ee9f0e286c0a1766}},
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
      howpublished = {\\url{https://solana.com/solana-whitepaper.pdf}},
      note         = {Defines Proof-of-History (PoH) as a verifiable-delay-function
                      clock for transaction ordering, used alongside a separate
                      consensus algorithm},
    }

    @misc{solana2019towerbft,
      author       = {{Solana Foundation}},
      title        = {Tower {BFT}: {S}olana's High Performance Implementation of {PBFT}},
      year         = {2019},
      month        = jul,
      howpublished = {\\url{https://solana.com/news/tower-bft--solana-s-high-performance-implementation-of-pbft}},
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
