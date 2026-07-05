#import "ieee-template.typ": ieee-conf
#import "@preview/equate:0.3.3": equate

#show: ieee-conf.with(
  title: [Architectural Design and Evaluation of a Peer-to-Peer Solar Energy Trading System via Smart Contracts on a Simulated Solana-compatible Consortium Network],
  authors: (
    (
      name: "Chanthawat Kiriyadee",
      affiliation: [
        Computer Engineering and Artificial Intelligence \
        University of the Thai Chamber of Commerce \
        Bangkok, Thailand
      ],
      email: "2410717302003@live4.utcc.ac.th",
    ),
  ),
  abstract: [The growing adoption of rooftop solar generation leaves many electricity users with surplus energy that they wish to trade directly. Yet direct Peer-to-Peer (P2P) electricity trading remains difficult, owing to grid constraints and the lack of a transparent price-formation mechanism. This paper presents the architectural design and evaluation of a P2P energy-trading system on a permissioned, governable consortium blockchain with predictable transaction cost. The core of the design is a clear separation of data verification from transaction settlement: off-chain verification is performed by an Aggregator Bridge that checks the Ed25519 signatures of meter readings before orders are matched by a Continuous Double Auction (CDA), while on-chain settlement records only verified matches and enforces correctness conditions at every step. The value of the work lies not in any single component but in the integration of all of them. Evaluation on a simulated system is consistent with this design: the ingest path sustains 80 meters at the design rate of 5.33 readings/s with no data loss, and under a step load up to 640 meters it keeps the loss ratio below 0.03%, with the measured ingest rate being a lower bound of a single sender client. The matching engine processes about 3.1 × 10#super[4] order pairs per second, and the single-pair on-chain settlement instruction costs about 97,000 compute units (80,000–103,000 across token-leg variants), roughly 48% of the default per-instruction budget. Meanwhile the settlement path is global-write-bound by design — every settlement must serialize on a central reconciliation write — which on a single validator yields a sub-1 transaction-per-second rate (about 0.5 TPS in a single recorded run, pending repeated measurement); even this conservative bound still supports about 450 settlements per 900-second clearing window, roughly an order of magnitude above the ≤ 40 matched pairs the tested 80-meter workload generates. These results support using the blockchain as a thin settlement layer. This is an architectural evaluation on a simulation, not a measurement on a real power system.],
  keywords: (
    "Consortium Blockchain",
    "Peer-to-Peer",
    "Continuous Double Auction",
    "Proof of Authority",
    "Microservices"
  ),
)

// Per-line equation numbering + shared alignment for grouped equation blocks.
#show: equate.with(breakable: true, sub-numbering: true)
#set math.equation(numbering: "(1.1)")

#include "sections/introduction-en.typ"
#include "sections/related-work-en.typ"
#include "sections/threat-model-en.typ"
#include "sections/settlement-model-invariants-en.typ"
#include "sections/pricing-market-mechanism-en.typ"
#include "sections/system-design-en.typ"
#include "sections/experimental-setup-en.typ"
#include "sections/evaluation-en.typ"
#include "sections/evaluation-bench-en.typ"
#include "sections/scale-onchain-validation-en.typ"
#include "sections/discussion_limitations-en.typ"
#include "sections/conclusion-en.typ"

#bibliography("references.bib", style: "ieee", title: [REFERENCES])
