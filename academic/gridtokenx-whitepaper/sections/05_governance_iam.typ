= Governance and Identity Management

A decentralized energy grid requires rigorous identity verification, transparent governance, and modular access control. GridTokenX implements a layered governance architecture that balances decentralization with the regulatory requirements of operating within a licensed utility environment.

== Identity and Access Management (IAM)

=== User Onboarding and KYC

All participants in the GridTokenX network — prosumers, grid operators, REC validators, and institutional traders — must complete a Know Your Customer (KYC) verification process before accessing trading functionality. This requirement is mandated by Thai financial regulations (AMLA 2542) and is enforced at both the application layer and the smart contract layer.

The KYC pipeline:

1. *Document Submission*: Users submit government-issued ID documents and a selfie via the GridTokenX mobile application. Documents are processed by an integrated third-party KYC provider (e.g., Jumio or Onfido) using automated OCR and liveness detection.

2. *AML Screening*: User names and identification numbers are screened against international sanctions lists (OFAC, UN, EU) and Thai domestic watchlists via an automated AML screening service.

3. *On-Chain Status Recording*: Upon successful KYC completion, the IAM Service submits a `register_user` transaction to the Solana Registry Program, recording the user's KYC tier (Basic, Standard, Enhanced) and wallet address in a `UserProfile` PDA.

4. *Tiered Access*: KYC tier determines trading limits:

#table(
  columns: (auto, auto, auto, 1fr),
  inset: 8pt,
  align: (left, center, center, left),
  [*KYC Tier*], [*Daily Limit (THB)*], [*REC Issuance*], [*Requirements*],
  [Basic], [10,000], [No], [National ID + selfie],
  [Standard], [500,000], [Yes], [Basic + address proof + bank account],
  [Enhanced], [Unlimited], [Yes], [Standard + business registration (for operators)],
)

=== Wallet Linkage

GridTokenX uses a non-custodial wallet model. Users generate their own Solana keypairs using the GridTokenX mobile app (which uses BIP-39 mnemonic generation with hardware-backed secure storage on iOS/Android). The wallet public key is linked to the user's KYC record in the Registry Program.

For institutional participants who require custodial key management, the platform supports integration with MPC (Multi-Party Computation) wallet providers, where the private key is distributed across multiple parties and no single party can sign unilaterally.

=== Role-Based Access Control (RBAC)

Internal service-to-service communication uses ConnectRPC with JWT-based authentication. Each service is assigned a service account with a specific role, and the IAM Service enforces that only authorized roles can invoke sensitive operations:

#table(
  columns: (auto, 1fr),
  inset: 8pt,
  align: (left, left),
  [*Role*], [*Permitted Operations*],
  [`oracle_bridge`], [Submit device readings, update MeterState PDAs],
  [`trading_service`], [Place/cancel orders, submit settlement intents],
  [`chain_bridge`], [Sign and broadcast Solana transactions],
  [`gthb_issuer`], [Mint/burn gTHB tokens, manage reserve attestations],
  [`governance_admin`], [Register REC validators, execute approved proposals],
  [`grid_operator`], [Update zone capacity limits, adjust wheeling charge factors],
)

Service JWTs are short-lived (15-minute expiry) and are automatically rotated by the IAM Service. Vault's AppRole authentication is used for service identity, ensuring that service credentials are never hardcoded in application configuration.

== On-Chain Governance

#figure(
  image("../figures/governance_lifecycle.svg", width: 100%),
  caption: [Governance proposal lifecycle from draft through execution, with emergency multisig bypass.],
) <fig-governance>

=== Governance Architecture

GridTokenX uses a two-tier governance model:

*Protocol Governance (GRX-weighted)*: Major protocol changes — fee structures, token economics, program upgrades — require a GRX-weighted vote. Any GRX holder can participate by staking their tokens in the Governance Program.

*Operational Governance (Multisig)*: Day-to-day operational parameters — zone capacity limits, wheeling charge adjustments, emergency circuit breakers — are managed by a 5-of-9 multisig composed of grid operators, the GridTokenX team, and independent technical advisors.

=== Proposal Lifecycle

```
Draft → Active → Succeeded/Defeated → Queued → Executed
  │         │                              │
  │    (7-day voting)              (48-hour timelock)
  │
  └── Requires 1,000 GRX to submit
```

*Quorum*: A proposal requires at least 10% of total staked GRX to vote for it to be valid.

*Approval Threshold*: A proposal passes if more than 60% of votes cast are in favor.

*Timelock*: Approved proposals are queued for 48 hours before execution, providing time for participants to exit positions if they disagree with the outcome.

=== Emergency Governance

In the event of a critical security vulnerability or market manipulation, the operational multisig can invoke emergency circuit breakers:
- *Market Pause*: Halts all new order placement and matching. Existing escrows remain locked.
- *Program Freeze*: Freezes a specific on-chain program, preventing any further instructions. Requires 7-of-9 multisig approval.
- *Emergency Withdrawal*: Allows users to withdraw escrowed funds during a market pause. Requires 9-of-9 multisig approval.

== Renewable Energy Certificates (RECs)

=== REC Standard and Compliance

GridTokenX's REC issuance process is designed to comply with the International REC Standard (I-REC) @irec, which is recognized in Thailand and across Southeast Asia. Each REC represents 1 MWh (1,000 kWh) of verified renewable energy generation.

=== REC Issuance Process

1. *Generation Accumulation*: As a prosumer's solar installation generates energy, GRID tokens are minted and the generation is recorded in the `MeterState` PDA.

2. *REC Application*: When a prosumer has accumulated 1,000 kWh of verified generation, they can apply for a REC through the Governance Program.

3. *Validator Review*: A registered REC Validator reviews the generation data, verifying:
   - The energy was generated from a qualifying renewable source (solar, wind, hydro).
   - The generation data is consistent with the device's rated capacity and historical performance.
   - No double-counting with other REC schemes.

4. *On-Chain Issuance*: The Validator co-signs a `issue_rec` transaction, creating an SPL Token-2022 token with metadata including:
   - Generation period (start and end timestamps).
   - Device ID and location (GPS coordinates, zone ID).
   - Fuel type (solar, wind, etc.).
   - I-REC certificate number.

5. *Trading and Retirement*: RECs can be traded on the GridTokenX marketplace or retired (burned) by corporate buyers to offset their carbon footprint. Retired RECs are recorded on-chain with the retiring entity's identity, providing an immutable audit trail.

=== Anti-Greenwashing Measures

The platform implements several measures to prevent fraudulent REC issuance:
- *Device Performance Monitoring*: The Oracle Bridge flags anomalous readings (e.g., generation exceeding the device's rated capacity) for manual review.
- *Cross-Reference Checking*: The IAM Service checks that a device is not registered in any other REC scheme before issuing GridTokenX RECs.
- *Validator Accountability*: REC Validators stake GRX tokens as collateral. Fraudulent validation results in stake slashing via a governance vote.
