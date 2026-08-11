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
  // leading/spacing tightened (0.55em/0.9em → 0.48em/0.65em) to fit the
  // market-clearing equations and the three-axis results inside the 2-page
  // limit; still looser than the template's Word "single line spacing".
  set par(justify: true, leading: 0.48em, spacing: 0.65em)

  // ── Heading numbering scheme: "1." / "1.1." ─────────────────
  set heading(numbering: "1.1.")

  // ── Heading appearance: BOLD, correct size ──────────────────
  // Level 1 → 11pt bold  (e.g. "1. Introduction")
  // Level 2 → 10pt bold  (e.g. "3.1. Equations and Data")
  show heading.where(level: 1): it => {
    v(0.5em, weak: true)
    // sticky: never leave a section heading stranded at the foot of a page
    block(sticky: true, text(
      size:   11pt,
      weight: "bold",
    )[#if it.numbering != none [#counter(heading).display("1.") ]#it.body])
    v(0.4em, weak: true)
  }

  show heading.where(level: 2): it => {
    v(0.5em, weak: true)
    block(sticky: true, text(
      size:   11pt,
      weight: "bold",
    )[#if it.numbering != none [#counter(heading).display("1.1.") ]#it.body])
    v(0.3em, weak: true)
  }

  // ── Equations: block, centred, numbered (n) right margin ────
  set math.equation(numbering: "(1)", block: true, supplement: none)
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
  show figure.caption: set text(size: 9pt)
  set figure(numbering: "1")

  // ── Figure/table spacing ─────────────────────────────────────
  set figure(gap: 2pt)
  show figure: set block(above: 3pt, below: 3pt)

  // ── Bibliography: IEEE numeric, heading unnumbered ───────────
  set bibliography(style: "ieee", title: "References")
  show bibliography: set heading(numbering: none)
  show bibliography: set text(size: 6.8pt)
  show bibliography: set par(leading: 0.28em, spacing: 0.32em)

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
        #super[\*]Corresponding author. *Contact:*
        #contact-email.split(", ").map(e => link("mailto:" + e)[#emph(e)]).join(", ")
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

// ── Booktabs-style table: horizontal rules only (top / under header /
//    bottom), no vertical or interior rules. ──────────────────────────
#let bt(columns: (), align: (), header: (), ..rows) = text(size: 7pt)[
  #table(
    columns: columns,
    align: align,
    stroke: none,
    inset: (x: 5pt, y: 1.3pt),
    table.hline(stroke: 0.7pt),
    table.header(..header.map(h => strong(h))),
    table.hline(stroke: 0.4pt),
    ..rows,
    table.hline(stroke: 0.7pt),
  )
]

// ── Abstract ───────────────────
// The growing adoption of renewable energy in Thailand has created participate with surplus generation capacity currently cannot engage in peer-to-peer (P2P), which MEA and PEA announce to buyback surplus energy totalling 500MWh from participate single price-rate 2.20THB/kWh and limitation 5kWh/participate.

// The adoption of the Thailand Power Development Plan (PDP 2026–2050), the national strategic framework for electricity generation and infrastructure targets a transition to at least 60% clean energy to achieve Net Zero greenhouse gas emissions by 2050.
// This article presents on-chain settlement layer for energy trading which transaction settlement executes on a Solana Permissioned Environments an settlement layer implemented as a modular Anchor smart-contract programs, and the consensus blocks finality driven by Solana Proof of History (PoH) Tower-BFT. Pricing mechanism incorporate continues double auction (CDA) matches the on-chain order-book in real time immediate trades with dynamic pricing.

// such as BESS reserved dispatch. Alongside the participates trade uniform price auction established a single clearing price over 15-minute time interval.
// consortium governance mapped to Thailand's grid operators. The application layer through Anchor smart contact program, consensus and finality Solana PoH/Tower-BFT engine, market design with hybrid a continuous double auction (CDA) matches the on-chain order book in real time immediate trades such as BESS reserve dispatch, uniform-price auction single clearing price over 15-minute.

// Thailand's Power Development Plan (PDP 2026-2050) mandates a transition to a minimum of 60% clean energy generation to fulfill the nation's carbon neutrality commitments. Achieving this target will necessitate a rapid proliferation of distributed rooftop solar prosumers. However, under the existing Enhanced Single Buyer model, these prosumers lack a direct mechanism for peer-to-peer (P2P) trading of surplus generation, resulting in the underutilization of distributed energy capacity.

Thailand's National Energy Trading Platform (NETP), envisaged since 2017 as a blockchain settlement layer for Peer-to-Peer (P2P) trading among rooftop-solar prosumers, remains in development on a Tendermint consortium chain, and the regulated buy-back gives prosumers no direct way to exchange surplus within the local distribution grid.
This paper asks what a parallel-execution runtime carries in that role, measured on the three axes a settlement layer is bought on: throughput, latency, and compute cost. Six modular Anchor programs run on a permissioned Solana network with every high-frequency write routed to a per-entity program-derived account (PDA), so transactions with disjoint write sets execute in parallel under Sealevel, ordered by Proof-of-History (PoH); above them a continuous double auction (CDA) and a uniform-price auction clear the book over fifteen-minute epochs.
Under that partition the per-meter write costs ≈13.5 k compute units (CU) and confirms at p50 ≈ 1.5–2.0 s (p95 ≤ 3.2 s), both unchanged from 80 to 200,000 meters; a simulated community-month (80 meters, 15% prosumers, 30 days at fifteen-minute intervals) replays at 1,858× real time with zero delivery loss and fourteen chain-derived conservation assertions all closing. The finding is what binds once partitioning removes computation as the limit: throughput is capped by a shared write-locked fee payer and single-node consensus rather than by per-entity contention, and settlement is packet-bound, not compute-bound. A match leaves half the 200 k CU budget unused, yet the 1,232-byte packet admits only one: denser settlement needs signatures repackaged, not more compute — a constraint transferable to any signature-verifying settlement layer. The price rule, not the platform, decides participation.

= Motivation and Design Rationale

Thailand's state utilities have advanced a National Energy Trading Platform (NETP) since 2017 for P2P trading among rooftop-solar prosumers, on a Tendermint-based consortium blockchain @netp2019report. This article presents a Solana-based architecture as an alternative execution layer, motivated by NETP's own finding that Tendermint outperformed Ethereum and Hyperledger Fabric — which suggests further gains from Solana's parallel-execution model. P2P market design and blockchain-based energy trading are well surveyed @sousa2019 @andoni2019 and demonstrated in pilots such as the Brooklyn Microgrid @mengelkamp2018; what such work reports is throughput and compute cost, presuming computation to be the axis along which a settlement layer scales. No study places a parallel-execution runtime in that role, which is the gap this paper addresses. The design under test partitions all hot-path state into per-entity PDAs; throughput, latency and compute cost are then measured together, so that what binds each can be named separately rather than attributed to computation by default.

= On-Chain Settlement Architecture

The settlement layer is six Anchor programs @anchor2024 (anchor-lang and anchor-spl 1.0.0) — *energy-token, governance, oracle, registry, trading,* and *treasury* — written in Rust and compiled to SBF bytecode. Programs invoke one another through cross-program invocation (CPI), authority delegated to program-derived addresses (PDAs) that sign without any private key. Routing every high-frequency write to a per-entity PDA keeps write sets disjoint, so such transactions never contend for one account lock and execute in parallel under Sealevel. The permissioned environment is a private `solana-test-validator` network; all experiments ran on a single node (Apple M2, Agave 3.1.10). A complete run must satisfy three closure identities, each checkable from chain state alone:

$ sum_(i,d) M(i,d) = E_"settle" = E_"burn", quad
  sum_i R(i) = 10^(-3) dot "REC supply", quad
  sum_m T_m = P_"sell" + W $ <eq-closure>

Here $M(i,d)$ is the GRID minted for prosumer $i$ on day $d$, $E_"settle"$ and
$E_"burn"$ the energy settled and burned, $R(i)$ the REC certified to $i$, and
$T_m$, $P_"sell"$, $W$ the per-match buyer debit, seller proceeds, and wheeling
charges. An audit harness re-derives the fourteen assertions behind
@eq-closure from chain state by RPC reads alone.

= Simulation Setup and Dataset

The fleet uses the CINELDI 80-bus rural LV reference grid (SINTEF) @cineldi2024 for topology only — the single-phase feeder with its V/A/W parameters — resolved for power flow with pandapower @thurner2018. As CINELDI carries only hourly load and no generation, all time-series are simulator-produced: per-meter consumption and twelve prosumer nodes' (15%) rooftop PV at fifteen-minute cadence, solar via pvlib @holmgren2018pvlib under a fixed seed (@tab-data).
Two further sweeps read per-write cost and latency against fleet size alone,
firing the oracle write from $N$ distinct meters over two epochs 61 s apart and
together covering $N = 80$ to 200,000 (1.35 M transactions); the second ran
unreset, its largest scale writing against 310,000 PDAs already on the ledger.

#figure(
  caption: [#text(size: 8pt)[The simulated community-month dataset
  (seed-deterministic; no field data).]],
  bt(
    columns: (auto, auto),
    align: (left + horizon, left + horizon),
    header: ([Quantity], [Value]),
    [fleet], [80 meters (seeded solar/load physics): 12 prosumer sellers, 68 consumers],
    [market policy], [sell cap #emph[C] = 10 kWh/day per prosumer; 0.1 kWh dust floor],
    [horizon / readings], [30 days × 96 ticks (Δ#emph[t] = 15 min) = 230,400 readings, integer Wh],
    [month energy], [15,868.5 kWh generated; 144,879.8 kWh consumed; 10,386.7 kWh interval surplus],
    [oracle-accepted surplus], [8,253.502 kWh; 919 readings gate-rejected],
  ),
) <tab-data>

= Results and Discussion

== Market-Clearing Model

Both P2P rules clear one book. The uniform-price auction cumulates supply $S$
ascending in ask and demand $D$ descending in bid and takes the crossing pair of
maximum volume, $(p^*, V^*) = op("arg max")_(p_s <= p_b) min(S(p_s), D(p_b))$,
priced at the marginal ask; the CDA fills each crossing pair pay-as-ask. Whichever
rule sets price $p$ on quantity $q$, one on-chain tariff taxes the seller in
integer micros with floored division:

$ V = floor.l q p \/ 10^9 floor.r, quad f = floor.l V phi \/ 10^4 floor.r, quad
  W = floor.l q w \/ 10^9 floor.r, quad L = floor.l V lambda \/ 10^4 floor.r,
  quad "net" = V - f - W - L $ <eq-tariff>

for fee $phi = 25$ bp and loss $lambda = 5$ bp on value and wheeling $w = 1.15$
THB/kWh flat on energy. Per kWh the seller keeps $p(1 - phi - lambda) - w =
0.997 p - 1.15$ regardless of volume, breaking even against the 2.20 THB/kWh
buy-back only above $p^dagger approx 3.36$.

== Measured Outcomes and Limitations

@tab-results reports all three axes with what bounds each; throughput is
client-observed confirmed goodput, with every non-confirmed transaction
attributed to a failure class.
*Compute is $O(1)$ and never binds:* the per-meter write holds 13.3–13.6 k CU
across the whole 2,500× range — the largest fleet writing against 310,000
already-resident PDAs at the same cost — and a match spends about half the
default budget. *Latency is set by block time, not by the partition:*
confirmation holds p50 ≈ 1.5–2.0 s and p95 ≤ 3.2 s over that range, flat where
a contended design would degrade. Being send→first-seen-confirmed it is
dominated by single-node block time (≈400–600 ms) and quantised by the ±1.5 s
poll — an upper bound on the runtime's own cost, not a measurement of it.

*Throughput is bound by serialization, not contention:* steady ingest holds
426–455 TPS from 10,000 to 200,000 meters — flat, not proportional, because one
write-locked gateway fee payer signs every transaction on one validator; the
PDAs are disjoint, so the ceiling lifts with payer pooling and more nodes, not a
finer partition. *Settlement density is packet-bound:* one match fits per
transaction. Its two 77-byte signed orders serialize to a 186-byte
instruction-data pair and are carried again, with signature and key, in two
≈189-byte Ed25519 verification instructions, so a second match overruns the
1,232-byte packet; Address Lookup Tables compress account keys, not instruction
data. Settlement stays exactly auditable, @eq-closure holding under all three
price rules.

#figure(
  caption: [#text(size: 8pt)[Measured outcomes by axis; #emph[sweep] figures come
  from the 80 → 200,000-meter ingest experiment, the rest from the
  community-month replay.]],
  bt(
    columns: (auto, auto, auto),
    align: (left + horizon, left + horizon, left + horizon),
    header: ([Axis], [Measurement], [What bounds it]),
      [compute], [13.3–13.6 k CU/reading #emph[(sweep)]; 107 k CU/match (≈54% of the 200 k budget)], [nothing — $O(1)$ in fleet size and state],
      [latency #emph[(sweep)]], [p50 ≈ 1.5–2.0 s, p95 ≤ 3.2 s, flat over the same range], [block time + ±1.5 s poll, not the partition],
      [throughput], [426–455 TPS steady ingest #emph[(sweep)]; ≈213 readings·s#super[−1] and ≈53 TPS order goodput in replay], [one write-locked fee payer, one node],
      [settlement density], [1 match/tx], [1,232-byte packet, not compute],
      [replay wall-clock], [1,394.7 s for 230,400 readings (1,858× real time)], [end-to-end lifecycle cost],
      [delivery loss], [0 unconfirmed; 919 readings gate-rejected], [validation, not lost throughput],
      [audit], [14/14 chain-derived assertions], [exactness of settlement],
  ),
) <tab-results>

A single validator bounds execution and locking only, not consensus in a
three-utility consortium. Sweep delivery loss stays ≤ 0.46%, exactly zero across
the later 1.02 M first-attempt sends; the 0.48% residual is a deliberate
anomaly-gate probe. Telemetry
reproduced bit-identically across four runs (213–232 readings·s#super[−1]);
lifecycle figures come from one canonical run, since nullifier PDAs make
identical replay impossible on a persistent ledger.

== Where the Prosumer's Revenue Goes

A secondary, economic result follows from the same runs: all three rules move
identical energy over one cleared month (1,111.4 kWh), so @eq-tariff alone sets
the ranking. Flat wheeling takes 1,278 THB from each P2P rule and nothing from
the buy-back — a third of the uniform auction's 3,834 THB gross — while the two
proportional charges take about 0.3%. The uniform auction nets 2.290 THB/kWh,
above $p^dagger$ and beating the 2.200 buy-back; the CDA fills cheaper rungs and
nets 2.065. The ranking reverses once supply is uncapped, so wheeling policy,
not the ledger, is the lever.

= Conclusion

Per-entity PDA partitioning carries a community-scale P2P market on a
permissioned Solana network: the full token life-cycle replays at 1,858× real
time with nothing lost, the ledger conserving energy and currency exactly.
Across the three axes the partition holds where it governs and yields where it
does not: compute is $O(1)$ over a 2,500× sweep and never binds, latency is flat
over that range and set by block time, and throughput is capped by one
write-locked fee payer on one node, not by per-entity contention. Only
settlement density resists: the packet, not the compute budget, limits a
transaction to one match, and that is where denser settlement must be won. A
multi-validator consortium mapped to EGAT, MEA, and PEA is the natural next
step, suited to UEC–ASEAN collaboration.

// The conclusion should highlight the main outcomes and suggest potential future
// work or collaboration opportunities between UEC and ASEAN partners.

#heading(numbering: none)[Acknowledgment]
The authors thank the University of the Thai Chamber of Commerce (UTCC) for institutional support, and the organizers — the UEC ASEAN Research Center (UARC) and Multimedia University (MMU) — for hosting this workshop.
// =============================================================================
//  REFERENCES
//  Option A (used here): inline bib database via `bibliography()` below.
//  Option B: keep a separate refs.bib and point to it.
// =============================================================================

#bibliography(
  bytes("
    % --- P2P energy markets and blockchain: prior art ---

    @article{sousa2019,
      author  = {Sousa, Tiago and Soares, Tiago and Pinson, Pierre and Moret, Fabio and
                 Baroche, Thomas and Sorin, Etienne},
      title   = {Peer-to-peer and community-based markets: A comprehensive review},
      journal = {Renewable and Sustainable Energy Reviews},
      volume  = {104},
      pages   = {367--378},
      year    = {2019},
      doi     = {10.1016/j.rser.2019.01.036},
    }

    @article{andoni2019,
      author  = {Andoni, Merlinda and Robu, Valentin and Flynn, David and Abram, Simone and
                 Geach, Dale and Jenkins, David and McCallum, Peter and Peacock, Andrew},
      title   = {Blockchain technology in the energy sector: A systematic review of
                 challenges and opportunities},
      journal = {Renewable and Sustainable Energy Reviews},
      volume  = {100},
      pages   = {143--174},
      year    = {2019},
      doi     = {10.1016/j.rser.2018.10.014},
    }

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