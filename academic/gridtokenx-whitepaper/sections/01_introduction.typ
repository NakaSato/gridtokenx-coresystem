= Introduction

== Background and Motivation

The global energy sector is undergoing a major structural transition. Driven by declining costs in photovoltaic (PV) technology, battery storage, and power electronics, distributed energy resources (DERs) are expanding rapidly. The International Energy Agency projects that distributed solar capacity alone will exceed 1,500 GW globally by 2030 @iea2023, with residential and commercial prosumers accounting for a growing share of total generation.

This decentralization of supply challenges the architecture of traditional power grids, which were designed around large, centralized generation assets dispatching power unidirectionally to passive consumers. Modern grids must now accommodate bidirectional power flows, frequency deviations caused by intermittent renewables, and the coordination of millions of independently operated assets — a task that centralized grid operators cannot solve through conventional dispatch alone.

Thailand, the primary deployment context for GridTokenX, exemplifies these pressures. The country's Alternative Energy Development Plan (AEDP 2018–2037) targets 30% renewable energy in the national mix by 2037 @aedp2037. Rooftop solar deployment has accelerated in recent years, yet tariff and net-metering structures often compensate surplus energy at administratively fixed rates below retail prices. This weakens economic incentives for prosumer investment and leaves grid flexibility underutilized.

== The Limitations of Existing P2P Energy Trading Solutions

Several peer-to-peer (P2P) energy trading pilots have been conducted globally, including the Brooklyn Microgrid @brooklyngrid, Power Ledger in Australia @powerledger, and various European transactive energy projects. While these initiatives have demonstrated technical feasibility, they share a common set of structural limitations:

*High Transaction Costs*: Ethereum-based solutions incur gas fees that are economically prohibitive for small-value energy trades (e.g., a 0.5 kWh transaction worth approximately 2 THB). Even Layer-2 solutions introduce settlement delays incompatible with real-time grid balancing.

*Data Silos and Trust Deficits*: Most platforms rely on a trusted central operator to aggregate meter data, creating a single point of failure and a potential vector for data manipulation. Participants cannot independently verify the provenance of energy they purchase.

*Lack of Real-Time Settlement*: Batch settlement cycles (hourly or daily) are incompatible with the sub-second dynamics of modern power grids. Frequency regulation and demand response require near-instantaneous financial signals to be effective.

*Regulatory Opacity*: Existing solutions struggle to integrate with national grid codes, wheeling charge frameworks, and REC certification standards, limiting their ability to operate within regulated utility environments.

*Scalability Ceilings*: Blockchain platforms with limited throughput cannot support the transaction volumes required for a national-scale energy market. A platform serving even a small fraction of a national utility's customer base would need to process many small orders, meter events, and settlement operations while keeping fees below the value of the traded energy.

== The GridTokenX Approach

GridTokenX is designed to address each of these limitations. The platform's core thesis is that a high-performance DePIN protocol — one that treats physical energy infrastructure as first-class participants in the settlement system — can support a decentralized, real-time energy market.

The key architectural decisions that differentiate GridTokenX are:

*Solana as Settlement Layer*: Solana's @solana2021 Proof-of-History (PoH) consensus mechanism and Sealevel parallel execution runtime provide low-latency finality, high theoretical throughput, and low transaction fees. These properties make Solana a suitable candidate for energy micro-settlement, provided that account contention and program compute-unit limits are controlled.

*Hardware-Rooted Trust*: Rather than relying on software attestation, GridTokenX anchors data integrity at the physical layer. Every IoT gateway is provisioned with an Ed25519 hardware security module that signs all telemetry at the source. This creates an unbroken cryptographic chain from the physical kilowatt-hour to the on-chain token.

*Continuous Double Auction (CDA)*: The CDA model, long established in financial markets @friedman1993, is well suited to real-time energy trading. Unlike AMM-based DEXes, the CDA supports limit orders, price discovery, and priority-based matching — essential properties for a market where supply and demand fluctuate continuously.

*Regulatory-Native Design*: GridTokenX is built to operate within, not around, existing regulatory frameworks. The wheeling charge model is designed to align with utility tariff concepts; the REC issuance process follows international I-REC principles @irec; and the KYC/AML pipeline is designed to support Thai financial regulatory requirements.

== Contributions of This Paper

This paper makes the following technical contributions:

1. A complete reference architecture for a DePIN energy trading platform, spanning hardware edge gateways, microservice orchestration, and on-chain smart contracts.

2. A formal description of the triple-token economic model (GRID, GRX, gTHB) and its incentive properties for prosumers, validators, and grid operators.

3. A detailed specification of the on-chain Continuous Double Auction matching engine, including sharded state management, atomic settlement, and replay protection mechanisms.

4. A grid-aware congestion management framework that enforces physical network constraints at the smart contract level, including zone-based wheeling charges, VPP capacity limits, and Grid Loss Factor accounting.

5. A security analysis covering the full attack surface from edge device compromise to on-chain exploit vectors, with corresponding mitigations.

== Paper Organization

The remainder of this paper is organized as follows. Section 2 reviews related work. Section 3 describes the overall system architecture. Section 4 details the blockchain and smart contract layer. Section 5 covers IoT edge ingestion and protocol translation. Section 6 presents the market mechanics and settlement engine. Section 7 describes governance and identity management. Section 8 details the token economics. Section 9 provides a security analysis. Section 10 covers grid-aware trading and congestion management. Section 11 defines the evaluation methodology and reproducibility requirements. Section 12 concludes with future directions.
