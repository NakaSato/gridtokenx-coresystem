= INTRODUCTION <sec:introduction>

The expansion of Renewable Energy (RE) has led many electricity users to shift from being purely consumers to being producers and consumers of energy at the same time (Prosumers). This change creates challenges for the traditional power grid, which was designed primarily for centralized distribution to end users. Research on Peer-to-Peer energy markets therefore focuses on trading mechanisms that preserve both the constraints of the grid and the reliability of the power system @tushar2020p2p @morstyn2019bilateral @paudel2019peer.

The transition toward Smart Grid systems in the Thai context, following the master plan for the development of Thailand's power grid, employs Advanced Metering Infrastructure (AMI), making energy production and consumption data more granular. Integrating Distributed Energy Resources (DER) such as rooftop solar photovoltaic systems, electric vehicle (EV) charging stations, and Battery Energy Storage Systems (BESS) must account for requirements on DER interconnection, Microgrid controllers, Islanding, and the constraints of the low-voltage grid @ieee1547_2018 @ieee2030_7 @guerrero2019decentralized.

This work makes three main contributions. First, a decoupled architecture design that clearly separates off-chain data verification through the Aggregator Bridge — namely Ed25519 signature verification of meter readings following the DLMS/COSEM standard and evaluation of grid stability conditions together with order matching via Continuous Double Auction (CDA) — from on-chain settlement. Second, the design of a trust boundary for settlement on an Anchor/Solana-compatible Proof of Authority (PoA) consortium network, where the blockchain verifies the Ed25519 signatures of both buyer and seller, prevents replay through an order nullifier and escrow state, while the energy-quantity conditions and oracle attestation are enforced in the off-chain layer, making the blockchain act clearly as a settlement and audit layer (see @sec:settlement-model). Third, the development of an AMI simulation suite that relies on grid modeling with pandapower and a Smart Meter Simulator to generate deterministic meter readings, together with a preliminary measurement of the ingest rate of the telemetry ingest path. The main distinction from prior work (see @sec:related-work) is not in any single component (consortium blockchain, CDA, or off-chain oracle, all of which exist in prior work), but in integrating these components through a clearly defined trust boundary: a zone-partitioned CDA over a consortium PoA network that clearly separates the off-chain telemetry verification layer (Ed25519/DLMS) from the settlement layer. The on-chain settlement mechanism at the core of this work is atomic delivery-versus-payment (DvP) that combines the Ed25519 signature verification of both parties, partial-fill replay prevention through an order nullifier, and a cross-zone flow cap into a single set of correctness conditions enforced within a single transaction, which prior work has not specified systematically. The scope of this work is an architectural design and evaluation on a simulation system, not a measurement from a field power grid or a production Solana network. The empirical contribution of this work is therefore a reproducible single-system characterization — namely the ingest rate, compute-unit cost, and throughput of the settlement path — rather than a head-to-head quantitative comparison with other platforms, which is future work.

On the economic-mechanism side, the system uses an energy token issued from actual production and certified by a Renewable Energy Certificate (REC; the on-chain system uses the identifier erc), together with a stablecoin pegged to the Thai baht (THBG) for pricing and settlement, and the GRX token for staking and governance. The details of the pricing model are described in @sec:pricing-market-mechanism, and the details of the relevant programs are described in @sec:smart-contract-programs.

This paper is organized as follows. @sec:related-work reviews related research on blockchain and Peer-to-Peer energy markets. @sec:threat-model defines the system, trust, and attacker models. @sec:settlement-model describes the system's settlement model. @sec:pricing-market-mechanism describes the CDA pricing mechanism and the settlement computation. @sec:system-architecture describes the architecture, connectivity, and key implementation details. @sec:experimental-setup specifies the experimental details and workload. @sec:evaluation summarizes the architectural evaluation, and @sec:discussion_limitations discusses results, limitations, and future development directions for the system. The acronyms frequently used in this paper are summarized in @tbl:acronyms.

#import "../glossary.typ": glossary-entries

#figure(
  kind: table,
  {
    set par(first-line-indent: 0pt, leading: 0.45em)
    let sorted = glossary-entries.sorted(key: e => lower(e.short))
    table(
      columns: (auto, 1fr),
      inset: (x: 4pt, y: 3pt),
      align: (left + top, left + top),
      table.header([Acronym], [Meaning]),
      ..sorted
        .map(e => (
          strong(e.short),
          if "description" in e [#e.long (#e.description)] else [#e.long],
        ))
        .flatten()
    )
  },
  caption: [Abbreviations used in this paper.],
) <tbl:acronyms>
