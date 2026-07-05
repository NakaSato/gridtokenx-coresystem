= RELATED WORK <sec:related-work>

Blockchain technology originated with Bitcoin @nakamoto2008bitcoin as a decentralized ledger system that requires no intermediary, and was extended to Smart Contract execution with Ethereum @buterin2014ethereum @wood2014ethereum. An overview of the technology and the classification of networks into permissionless and permissioned types was summarized by NIST @yaga2018blockchain, which serves as a reference framework for selecting a network architecture suited to governance requirements.

In the context of Peer-to-Peer energy markets, a large body of research has studied market mechanisms and auction design. Mengelkamp et al. @mengelkamp2018blockchain compared local energy market designs and bidding strategies, while Munsing et al. @munsing2017blockchains proposed using blockchain for decentralized optimization of energy resources in microgrid networks. These works highlight the potential of blockchain to support direct energy trading between users, but most still evaluate on public networks that are constrained by transaction cost and block-confirmation latency. A recent concrete example is the decentralized trading platform of Esmat et al. @esmat2021decentralized, which develops a market mechanism and settlement on a public blockchain (Ethereum) but does not clearly separate the off-chain data-verification layer from on-chain settlement.

To address governance and cost predictability, a number of studies have turned to consortium or permissioned networks. Kang et al. @kang2017consortium used a consortium blockchain for Peer-to-Peer electricity trading among plug-in electric vehicles, and Hyperledger Fabric @androulaki2018hyperledger is an example of a distributed operating system for permissioned networks with clearly defined participant permissions. On the consensus side, the Byzantine Generals problem @lamport1982byzantine and the Practical Byzantine Fault Tolerance algorithm @castro1999practical form the theoretical foundation for transaction confirmation in networks with a limited number of nodes, consistent with the permissioned-network assumption that governs validator admission via Proof of Authority (PoA) in this work (here PoA is an admission/governance layer, while Layer 1 consensus still relies on PoH together with Tower BFT).

The systematic review of Andoni et al. @andoni2019blockchain comprehensively surveys blockchain applications in the energy sector and identifies scalability, cost, and governance as the main challenges, providing a foundational reference frame for this body of research. Recent literature reviews further reflect that this remains an open research area. Tanis et al. @tanis2025p2preview comprehensively reviewed the market structure, operational layers, and multi-energy systems of Peer-to-Peer trading, while Bhavana et al. @bhavana2024blockchain surveyed blockchain applications in energy markets and green hydrogen supply chains, pointing out that scalability, cost, and regulatory compliance remain the main challenges. In addition, a comparative evaluation of consensus mechanisms for Peer-to-Peer energy trading in microgrids @bhavana2025consensus supports the choice of a permissioned network with controlled permissions, consistent with the PoA-based admission/governance assumption used in this work.

Unlike the works above, this article focuses on the design and evaluation of the architecture of a simulation system that clearly separates off-chain verification through the Aggregator Bridge from the settlement layer on the blockchain. The scope of this work is therefore architectural design and evaluation, not the reporting of measurements from a field electrical grid or a Solana production network; the energy data used in the prototype comes from an AMI Simulator, and what is recorded on the blockchain is a settlement event that has already been verified by the Backend/Aggregator Bridge, consistent with the preliminary guidance for testing microgrid control systems @ieee2030_8. The positioning of this work relative to works that use blockchain for Peer-to-Peer energy markets is summarized in @tbl:comparison, where the main distinction is the integration of zone-partitioned CDA on a PoA-based consortium network with the clear separation of the off-chain meter-telemetry verification layer (Ed25519/DLMS) from the settlement layer. Note that @tbl:comparison is a qualitative positioning, since these works run on different networks, datasets, and assumptions, and therefore share no quantitative metric that is directly comparable.

#figure(
  placement: top,
  scope: "parent",
  caption: [Positioning of this work vs. prior blockchain-based P2P energy-trading studies.],
  [
    // Zebra rows for scanability; the final row (this work) is tinted + bold.
    #show table.cell.where(y: 6): set text(weight: "bold")
    #table(
      columns: (1.5fr, 1.1fr, 1.1fr, 1.3fr, 1.5fr),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, left + horizon, left + horizon, left + horizon, left + horizon),
      fill: (x, y) => if y == 6 { rgb("#eef3fb") } else if y > 0 and calc.odd(y) { luma(249) },
      table.header(
        [Work], [Network], [Consensus], [Market mechanism], [Off/on-chain separation],
      ),
      [Mengelkamp @mengelkamp2018blockchain], [Public (LEM)], [Public], [Local market / bidding], [Not clearly separated],
      [Munsing @munsing2017blockchains], [Public], [Public], [Decentralized optimization], [Not clearly separated],
      [Kang @kang2017consortium], [Consortium], [Consortium], [Iterative double auction], [Partial],
      [Hyperledger Fabric @androulaki2018hyperledger], [Permissioned], [Pluggable (Raft/BFT)], [Platform (not market-specific)], [—],
      [Esmat @esmat2021decentralized], [Public (Ethereum)], [Public], [Double auction], [Partial],
      [This work], [Consortium \ (Solana-compatible)], [PoH + Tower BFT \ (PoA admission/governance)], [CDA price-time \ zone-partitioned], [Clearly separated + \ Ed25519/DLMS telemetry],
    )
  ],
) <tbl:comparison>
