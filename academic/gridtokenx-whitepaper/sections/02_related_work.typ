= Related Work

GridTokenX builds on three adjacent research areas: peer-to-peer energy trading, transactive energy control, and blockchain-based infrastructure coordination. Existing work demonstrates that decentralized market mechanisms can improve local renewable utilization, but also shows that physical grid constraints, participant identity, metering trust, and regulatory integration remain unresolved barriers to production deployment.

== Peer-to-Peer and Community Energy Markets

Peer-to-peer energy trading has been extensively studied as a mechanism for allowing prosumers to exchange surplus generation directly rather than selling all exports to a central utility. Comprehensive reviews by Tushar et al. @tushar2020 and Sousa et al. @sousa2019 identify recurring design dimensions: market clearing mechanism, network tariff allocation, local grid constraint handling, privacy, and settlement assurance. These reviews show that many P2P proposals assume a simplified distribution network or defer physical feasibility checks to the distribution system operator.

Zhang et al. @zhang2018 demonstrate a microgrid-level P2P energy trading model in which local participants can trade through a market mechanism rather than relying only on fixed tariffs. Their work validates the economic motivation for local energy markets, but the model is primarily microgrid-scoped and does not address cryptographic metering provenance, tokenized settlement, or national-scale participant onboarding.

The Brooklyn Microgrid case study @brooklyngrid is one of the best-known practical demonstrations of blockchain-enabled community energy markets. It illustrates the social and technical feasibility of local energy exchange, but also highlights a limitation shared by many pilots: the market is bounded to a small local community and relies on a deployment context where regulatory, metering, and grid-operation assumptions are tightly controlled.

== Transactive Energy and Market Mechanisms

Transactive energy research frames distributed energy resources as autonomous devices that can respond to price signals and operational constraints @kok2016. GridTokenX adopts this framing but adds explicit on-chain settlement, identity-gated participation, and REC issuance. The Continuous Double Auction (CDA) selected for GridTokenX follows established market microstructure literature @friedman1993 and is preferred over an automated market maker because energy is time-bound, location-dependent, and capacity-constrained.

Compared with batch-cleared community markets, a CDA can represent limit prices, partial fills, and price-time priority. However, CDA alone is insufficient for power systems because a financially matched trade may still be physically infeasible. GridTokenX therefore couples the CDA with zone-level capacity checks, dynamic wheeling charges, and Grid Loss Factor accounting.

== Blockchain and Decentralized Settlement

Blockchain settlement originates from peer-to-peer digital cash systems @nakamoto2008, but energy trading imposes requirements that differ from purely financial transfers. Settlement must be linked to measured physical generation, user eligibility, delivery constraints, and regulatory auditability. Earlier blockchain energy pilots show that tamper-resistant ledgers can improve transparency, but transaction cost, throughput, and off-chain data trust remain common bottlenecks @brooklyngrid @powerledger.

GridTokenX differs from these systems by separating low-latency off-chain matching from trust-critical on-chain settlement, using hardware-signed telemetry as the root of token minting, and enforcing participant eligibility through on-chain registry state. Solana is selected because its parallel execution model and low fees are better aligned with small-value energy transactions than higher-cost settlement layers @solana2021.

== Research Gap

The gap addressed by this paper is not the existence of P2P trading in isolation. Prior work has already established that P2P and community energy markets are technically and economically plausible. The unresolved problem is an end-to-end architecture that combines:

- cryptographic provenance from the physical meter to the settlement token,
- low-cost micro-settlement suitable for sub-kWh trades,
- identity and REC compliance for regulated energy markets,
- market matching that respects grid topology and wheeling charges,
- reproducible evaluation across matching throughput, on-chain compute budget, and power-flow feasibility.

GridTokenX is proposed as a reference architecture for this combined problem.
