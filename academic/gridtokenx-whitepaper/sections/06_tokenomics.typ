= Token Economics and Stable Settlement

GridTokenX employs a sophisticated triple-token ecosystem designed to balance real-world energy representation, platform utility, and transactional stability. Each token serves a distinct economic function, and their interactions create a self-reinforcing incentive structure that aligns the interests of all network participants.

== The Triple-Token Model

#figure(
  image("../figures/token_flow.svg", width: 100%),
  caption: [Triple-token lifecycle: GRID energy token, GRX utility token, and gTHB settlement stablecoin.],
) <fig-tokens>

=== GRID — The Energy Token

GRID is the fundamental unit of account for energy on the GridTokenX platform. Its design is governed by three core properties:

*Physical Backing*: 1 GRID = 1 kWh of verified renewable energy. GRID tokens are minted only upon cryptographic proof of generation (Oracle Program CPI) and REC Validator co-signature. This ensures that the total GRID supply at any point in time exactly reflects the total verified renewable energy available on the platform.

*Consumption Burning*: When a buyer receives GRID tokens and the corresponding energy is delivered to their premises (confirmed by the buyer's meter reading), the GRID tokens are burned from the buyer's account. This closes the economic loop: tokens are created when energy is generated and destroyed when energy is consumed, maintaining a real-time reflection of net available energy.

*SPL Token-2022 Features*: GRID leverages the Token-2022 program's transfer hook extension to enforce trading rules (e.g., KYC verification of both parties) on every transfer, and the interest-bearing extension to implement time-decay for tokens representing energy that has not been traded within a configurable window (preventing stale energy from accumulating indefinitely).

=== GRX — The Utility and Governance Token

GRX is the native utility and governance token of the GridTokenX protocol. It serves multiple functions:

*Staking for Network Roles*:
- *Oracle Node Operators*: Must stake a minimum of 10,000 GRX to operate an Oracle Bridge node. Stake is slashed for submitting invalid data.
- *REC Validators*: Must stake 50,000 GRX to register as a validator. Stake is slashed for fraudulent REC issuance.
- *Grid Operators*: Must stake 100,000 GRX to manage a zone and receive wheeling charge revenue.

*Governance Voting*: GRX holders vote on protocol parameter changes proportional to their staked balance. Unstaked GRX cannot vote, incentivizing long-term commitment to the protocol.

*Fee Discounts*: Traders who hold and stake GRX receive tiered discounts on market fees:

#table(
  columns: (auto, auto, auto),
  inset: 8pt,
  align: (left, center, center),
  [*Staked GRX*], [*Market Fee*], [*Discount*],
  [0 – 999], [0.10%], [0%],
  [1,000 – 9,999], [0.08%], [20%],
  [10,000 – 99,999], [0.06%], [40%],
  [100,000+], [0.04%], [60%],
)

*Token Supply and Distribution*:

Total supply: 1,000,000,000 GRX (fixed, no inflation)

#table(
  columns: (1fr, auto, auto),
  inset: 8pt,
  align: (left, center, center),
  [*Allocation*], [*Amount (GRX)*], [*Vesting*],
  [Ecosystem & Rewards], [400,000,000 (40%)], [10-year linear emission],
  [Team & Advisors], [150,000,000 (15%)], [4-year, 1-year cliff],
  [Investors (Seed + Series A)], [200,000,000 (20%)], [3-year, 6-month cliff],
  [Protocol Treasury], [150,000,000 (15%)], [Governance-controlled],
  [Public Sale], [50,000,000 (5%)], [No lock-up],
  [Liquidity Provision], [50,000,000 (5%)], [2-year linear],
)

=== gTHB — The Settlement Stablecoin

gTHB is a reserve-backed stablecoin pegged 1:1 to the Thai Baht (THB). It serves as the exclusive settlement currency for energy trades on the GridTokenX platform, isolating participants from cryptocurrency market volatility.

*Reserve Management*: Every gTHB in circulation is backed by an equivalent amount of THB held in segregated accounts at licensed Thai commercial banks. The reserve is managed by a licensed trust company and is subject to quarterly independent audits.

*Mint/Burn Lifecycle*:
- *Minting*: A user deposits THB via bank transfer to the reserve account. Upon confirmed receipt (verified by the bank's API), the gTHB Issuer Service submits a mint transaction. Routine mints are processed automatically via a threshold MPC signing pipeline once KYC and AML checks pass; large institutional mints above a configurable threshold trigger an asynchronous multi-party approval workflow.
- *Burning*: A user submits a redemption request. The gTHB Issuer burns the tokens on-chain and initiates a THB bank transfer to the user's registered bank account within 1 business day.

*Transparency*: The platform publishes real-time reserve attestations via a public API, showing total gTHB supply and total THB reserves. Quarterly audit reports from an independent accounting firm are published on the platform's website and referenced on-chain via IPFS content hashes.

== Token Flow Mechanics

The following describes the complete economic flow for a typical prosumer energy trade:

```
Prosumer A (Seller)                    Prosumer B (Buyer)
     │                                       │
     │ Solar generation confirmed            │ Deposits THB
     │ by Oracle Bridge                      │ via bank transfer
     ▼                                       ▼
GRID tokens minted (1 GRID/kWh)        gTHB tokens minted (1 gTHB/THB)
     │                                       │
     │ Places ASK order                      │ Places BID order
     │ (e.g., 3.50 THB/kWh)                 │ (e.g., 3.60 THB/kWh)
     ▼                                       ▼
              CDA Matching Engine
              (match at 3.50 THB/kWh)
                      │
                      ▼
              On-Chain Settlement
              ┌─────────────────────────────────┐
              │ GRID: A → B (10 kWh)            │
              │ gTHB: B escrow → A (35.00 THB)  │
              │ gTHB: B escrow → Grid Op (5 THB)│ ← wheeling charge
              │ gTHB: B escrow → Treasury (0.035│ ← market fee
              │        THB)                     │
              └─────────────────────────────────┘
                      │
                      ▼
     GRID tokens burned when B's meter
     confirms energy consumption
```

== Incentive Analysis

=== Prosumer Incentives

Prosumers are incentivized to participate by receiving market-rate prices for their surplus energy — significantly higher than the fixed net-metering rate offered by the PEA. A prosumer with a 5 kW rooftop solar installation generating 20 kWh/day of surplus energy could earn approximately 70 THB/day at a market price of 3.50 THB/kWh, compared to approximately 20 THB/day under the PEA's net-metering rate of 1.00 THB/kWh.

=== Validator Incentives

Oracle Node Operators and REC Validators earn fees for their services:
- Oracle Nodes receive 0.001 GRX per validated meter reading.
- REC Validators receive 0.5 GRX per issued REC.

These fees are funded from the Ecosystem & Rewards allocation and are designed to cover operational costs while providing a reasonable return on staked capital.

=== Grid Operator Incentives

Grid operators receive wheeling charge revenue proportional to the energy traded through their zones. This creates a direct financial incentive for operators to maintain grid infrastructure and expand capacity to accommodate growing DER penetration.

== Economic Security Analysis

=== Token Price Stability

The GRID token's value is anchored to the physical energy market. As long as the platform maintains a competitive market with sufficient liquidity, GRID prices should converge to the marginal cost of renewable energy production in each zone. This provides a natural price floor and ceiling, reducing speculative volatility.

The gTHB stablecoin's peg is maintained by the reserve mechanism. Unlike algorithmic stablecoins, gTHB has no algorithmic component — it is fully collateralized at all times, making it immune to the "death spiral" dynamics that have affected algorithmic stablecoins.

=== Attack Resistance

The staking requirements for network roles create economic barriers against Sybil attacks. An attacker attempting to register fraudulent Oracle nodes would need to stake significant GRX capital, which would be slashed upon detection of malicious behavior. The cost of a successful attack exceeds the potential gain in all modeled scenarios.
