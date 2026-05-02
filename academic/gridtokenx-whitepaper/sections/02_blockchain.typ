= Blockchain and Smart Contracts

GridTokenX leverages the Solana blockchain for its sub-second finality, high-throughput Sealevel parallel execution runtime, and negligible transaction fees — properties that are essential for a real-time energy market operating at grid frequency.

== Why Solana

The selection of Solana @solana2021 as the settlement layer was driven by a rigorous evaluation of available blockchain platforms against the specific requirements of real-time energy trading:

#table(
  columns: (1fr, auto, auto, auto),
  inset: 8pt,
  align: (left, center, center, center),
  [*Requirement*], [*Ethereum L1*], [*Polygon PoS*], [*Solana*],
  [Finality (seconds)], [\~900], [\~2], [*\<0.4*],
  [Throughput (TPS)], [\~15], [\~7,000], [*65,000+*],
  [Tx Fee (USD)], [\$0.50--50], [\$0.001], [*\$0.00025*],
  [Parallel Execution], [No], [No], [*Yes (Sealevel)*],
  [Native Token Program], [ERC-20], [ERC-20], [*SPL Token-2022*],
)

Solana's Proof-of-History (PoH) mechanism provides a cryptographic clock that orders transactions without requiring validators to communicate timestamps, enabling the Sealevel runtime to execute non-overlapping transactions in parallel. This is critical for GridTokenX, where thousands of independent prosumer trades can be settled simultaneously without contention.

== Anchor Workspace and Program Inventory

The on-chain logic is implemented as a unified Anchor @anchor workspace. The system is decomposed into five specialized programs, each serving a critical role in the decentralized energy lifecycle. All programs are deployed as upgradeable programs under a governance-controlled upgrade authority.

=== Registry Program

The Registry Program manages decentralized identity (DID) and hardware device registration. It serves as the root of trust for all participants in the network.

*Key Instructions*:
- `register_user`: Creates a `UserProfile` PDA containing KYC status, wallet address, and zone assignment. Requires a co-signature from the IAM Service to enforce KYC verification.
- `register_device`: Creates a `DeviceRegistry` PDA storing the device's Ed25519 public key, device type (meter, EV charger, BESS), and associated prosumer wallet. Enables the Oracle Program to verify device signatures on-chain.
- `update_kyc_status`: Updates a user's KYC tier, gating access to higher trading limits and REC issuance.

*Sharding Architecture*: The Registry uses a 16-shard design. User and device PDAs are assigned to shards based on the first byte of their public key. This prevents write-lock contention on a single global state account during high-volume onboarding periods, enabling parallel registration transactions.

=== Oracle Program

The Oracle Program is the on-chain entry point for physical energy data. It validates and records verified energy measurements, forming the basis for token minting.

*Key Instructions*:
- `submit_reading`: Accepts a signed telemetry payload from the Oracle Bridge. Verifies the Ed25519 device signature using the `instructions` sysvar (cross-instruction verification), updates the `MeterState` PDA with cumulative generation and consumption, and emits a `ReadingSubmitted` event.
- `finalize_interval`: Closes a measurement interval and computes the net energy delta eligible for tokenization. Triggers a CPI (Cross-Program Invocation) to the Energy Token Program to mint GRID tokens.

*State Design*: Each registered device has a dedicated `MeterState` PDA storing:
```
pub struct MeterState {
    pub device_id: Pubkey,
    pub cumulative_generation_wh: u64,
    pub cumulative_consumption_wh: u64,
    pub last_reading_ts: i64,
    pub interval_generation_wh: u64,
    pub pending_mint_wh: u64,
    pub bump: u8,
    pub _padding: [u8; 6],
}
```

=== Energy Token Program

The Energy Token Program is a high-performance tokenization layer built on SPL Token-2022 @spltoken. It manages the full lifecycle of GRID and GRX tokens.

*GRID Token*: Represents verified renewable energy. 1 GRID = 1 kWh. Minting requires:
1. A CPI from the Oracle Program confirming verified generation.
2. A co-signature from a registered REC Validator, ensuring renewable provenance.
3. The prosumer's wallet must have an active, KYC-verified `UserProfile`.

*GRX Token*: The platform's utility and governance token. Fixed supply of 1,000,000,000 GRX. Distribution is governed by the vesting schedule defined in the Governance Program.

*Lazy Supply Sync*: To avoid global write-locks on the token mint account during high-frequency minting, the program uses a lazy synchronization pattern. Individual mint operations update a per-shard supply counter. A periodic `sync_supply` instruction aggregates shard counters into the canonical mint account, executed by a cron job during low-traffic periods.

=== Trading Program

The Trading Program implements the platform's decentralized exchange (DEX) with a Continuous Double Auction (CDA) matching engine.

*Key Instructions*:
- `place_order`: Creates an `Order` PDA with price, quantity, order type (buy/sell), and expiry. For buy orders, locks the corresponding gTHB amount in a program-owned escrow account.
- `match_orders`: The settlement instruction. Accepts up to 4 buy-sell order pairs per transaction. For each pair:
  1. Verifies Ed25519 signatures for both buyer and seller order payloads (cross-instruction verification).
  2. Checks nullifier PDAs to prevent replay.
  3. Executes atomic SPL token transfers: GRID from seller to buyer, gTHB from escrow to seller.
  4. Deducts wheeling charges and market fees, transferring them to the grid operator and protocol treasury accounts.
  5. Records the match in the `MarketShard` PDA and creates a `Nullifier` PDA for each settled order.
- `cancel_order`: Cancels an open order and releases escrowed funds back to the buyer.

*Sharded Market State*: The order book state is distributed across 32 `MarketShard` PDAs, assigned by order ID hash. This enables up to 32 concurrent settlement transactions to execute in parallel without account lock contention.

=== Governance Program

The Governance Program controls protocol-wide parameters and manages the REC certification lifecycle.

*Key Instructions*:
- `propose_parameter_change`: Creates a governance proposal to modify protocol parameters (e.g., market fee rate, wheeling charge multipliers, VPP capacity limits).
- `vote`: Records a GRX-weighted vote on an active proposal. Voting power is proportional to staked GRX balance.
- `execute_proposal`: Executes an approved proposal after the timelock period, updating the `ProtocolConfig` PDA.
- `register_rec_validator`: Registers an authorized REC validator organization. Only validators registered here can co-sign GRID token mints.
- `issue_rec`: Issues a fractionalized Renewable Energy Certificate as an SPL Token-2022 token with metadata conforming to the I-REC standard @irec.

== Performance Invariants and State Management

=== Zero-Copy State

All high-frequency on-chain state structs use the `#[account(zero_copy)]` attribute with `#[repr(C)]` layout and explicit padding:

```rust
#[account(zero_copy)]
#[repr(C)]
pub struct MarketShard {
    pub shard_id: u8,
    pub total_matches: u64,
    pub total_volume_wh: u64,
    pub total_volume_gthb: u64,
    pub last_match_ts: i64,
    pub _padding: [u8; 7],
}
```

Zero-copy deserialization avoids heap allocation and memcpy overhead, reducing compute unit consumption by approximately 30% for complex settlement instructions compared to standard Borsh deserialization.

=== Compute Unit Optimization

Every instruction handler is profiled using `sol_log_compute_units()` during development. Target CU budgets:
- `submit_reading`: ≤ 15,000 CU
- `match_orders` (4 pairs): ≤ 180,000 CU (well within the 200,000 CU per-instruction limit)
- `place_order`: ≤ 12,000 CU

=== Trustless Bridge Integration

The Chain Bridge service interfaces with Solana through a dedicated RPC proxy that implements:
- *Preflight Simulation*: All transactions are simulated before broadcast to detect failures early and avoid wasting fees.
- *Priority Fees*: Settlement transactions include compute unit price instructions to ensure timely inclusion during network congestion.
- *Retry Logic*: Exponential backoff with jitter for failed broadcasts, with a maximum of 5 retries before escalating to the dead-letter queue.
- *Confirmation Tracking*: The bridge subscribes to transaction confirmation via WebSocket and publishes confirmed/failed events to NATS within 500ms of finality.
