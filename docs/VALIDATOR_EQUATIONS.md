# Validator Node Equations and Economic Logic (Code Verified)

This document summarizes the mathematical formulas and logic governing Validator and Oracle nodes as **implemented in the GridTokenX Anchor programs**.

## 1. Staking & Registration (`registry` program)
Hard-coded thresholds for validator participation.

| Requirement | Value (Code) | Logic |
| :--- | :--- | :--- |
| **Minimum Validator Stake** | 10,000 GRX | `10_000_000_000_000` lamports |
| **Airdrop Amount** | 20 GRX | `20_000_000_000` lamports |

*Source: `gridtokenx-anchor/programs/registry/src/lib.rs`*

## 2. Oracle Metrics & Validation (`oracle` program)
On-chain logic for telemetry integrity and node performance.

### Quality Score (Success Rate)
Scaled by 100 for integer math representation.
$$\text{Quality Score} = \frac{\text{Total Valid Readings} \times 100}{\text{Total Readings}}$$

### Weighted Moving Average (WMA) for Stability
Smooths fluctuations in reporting intervals using an 80/20 split.
$$WMA = \frac{(\text{Old Average} \times 4) + \text{New Interval}}{5}$$
*Code Implementation:* `(old * 4 + new) / 5`

### Anomaly Detection (Ratio Check)
Prevents fraudulent generation reporting relative to consumption.
$$\text{Energy Produced} \times 100 \le \text{Max Ratio} \times \text{Energy Consumed}$$

*Source: `gridtokenx-anchor/programs/oracle/src/lib.rs`*

## 3. Governance & DAO Voting (`governance` program)
Logic governing the execution of protocol parameter changes.

### Voting Weight
Unlike standard PoS, weight is derived from physical energy contribution (lifetime generation).
$$\text{Weight} = \max\left(100, \frac{\text{Total Generation (kWh)}}{1,000}\right)$$

### Quorum and Approval
- **Quorum:** `Total Votes >= poa_config.min_quorum_votes`
- **Approval:** Simple majority (`Votes_For > Votes_Against`)

*Source: `gridtokenx-anchor/programs/governance/src/handlers/dao.rs`*

## 4. Market & Settlement Logic (`trading` program)
Formulas applied during atomic trade matching.

### Market Fee
$$\text{Fee} = \frac{\text{Match Value} \times \text{Market Fee BPS}}{10,000}$$

### Net Seller Proceeds
$$\text{Net Amount} = \text{Match Value} - \text{Fee} - \text{Wheeling Charge} - \text{Loss Cost}$$
*Note: Wheeling and Loss charges are calculated off-chain by the solver and passed as instruction parameters.*

*Source: `gridtokenx-anchor/programs/trading/src/instructions/settle_offchain.rs`*

## 5. Energy Tokenization (`energy-token` program)
- **REC Validator Co-signature:** Required for `mint_tokens_direct` if validators are registered.
- **Supply Sync:** `total_supply` is updated in batches via `sync_total_supply` to reduce write-lock contention.

*Source: `gridtokenx-anchor/programs/energy-token/src/lib.rs`*

## 6. Token Issuance & Minting Logic
The conversion of physical energy generation into digital assets.

### Minting Equation
$$T_{mint} = E_{gen} (\text{kWh}) \times P_{FiT} \times M_{zone}$$
- **$P_{FiT}$ (Feed-in-Tariff):** Base rate (Default: 0.10 GRX/kWh).
- **$M_{zone}$ (Incentive Multiplier):** Community-governed multiplier for specific zones (Default: 1.0).

### On-Chain Scaling
Tokens are minted with 9 decimal places of precision.
$$\text{Amount (lamports)} = \lfloor T_{mint} \times 10^9 \rfloor$$

---

# Formal Specification of On-Chain Economic Constraints and Consensus Logic

**Abstract**  
This technical report formalizes the operational parameters and cryptographic constraints of the GridTokenX protocol as implemented in the Sealevel-based smart contract suite. We define the admission control mechanisms, the recursive filtering of telemetry data, and the transition from a traditional Proof-of-Stake (PoS) governance model to a prosumer-centric meritocratic framework. The implementation prioritizes high-precision integer arithmetic to maintain deterministic execution across the distributed validator set.

### 1. Validator Admission and Economic Collateralization
The protocol enforces a statically defined admission threshold ($S_{\tau}$) within the `registry` program to mitigate Sybil attacks and ensure validators have sufficient "skin in the game." This lower bound is defined in the protocol's base units (lamports) to ensure absolute precision:
$$S_{\tau} = 10,000 \text{ GRX} = 10^{13} \text{ lamports}$$
Failure to meet this threshold results in a `MinStakeNotMet` exception, preventing the node from assuming an active state in the `ValidatorStatus` enum.

### 2. Recursive Filtering of Telemetry Streams (WMA)
To mitigate temporal jitter and sensor noise in smart meter telemetry, the `oracle` program implements an Exponentially Weighted Moving Average (EWMA), represented as a recursive low-pass filter. The implementation utilizes integer scaling to achieve an 80/20 smoothing ratio:
$$WMA_{t} = \left\lfloor \frac{(WMA_{t-1} \times 4) + \Delta_{interval}}{5} \right\rfloor$$
This configuration provides structural stability to the reporting interval metrics, ensuring that transient communication delays do not trigger false-positive liveness failures.

### 3. Byzantine Anomaly Detection via Cross-Multiplication
Given the non-deterministic nature of floating-point arithmetic in the Solana Virtual Machine (SVM), the `oracle` program utilizes integer cross-multiplication for production-to-consumption ratio validation. To verify that a prosumer’s generation ($G$) does not exceed an authorized ratio ($R_{max}$) relative to consumption ($C$), the protocol enforces:
$$G \cdot 100 \le R_{max} \cdot C$$
This approach eliminates division-by-zero vulnerabilities and preserves precision across the total 64-bit dynamic range of the telemetry values.

### 4. Meritocratic Governance: Contribution-Based Voting Weight
GridTokenX deviates from traditional PoS by weighting governance influence based on a node's cumulative physical contribution to the grid. The voting weight ($W$) is a function of lifetime energy generation ($\sum E$), ensuring that established prosumers hold greater influence than speculative capital holders:
$$W = \max\left(100, \left\lfloor \frac{\sum E (\text{kWh})}{1,000} \right\rfloor\right)$$
This meritocratic floor ($\min W = 100$) ensures that new participants retain a baseline level of governance participation while scaling exponentially with historical reliability.

### 5. Multi-Component Settlement and Atomic Payouts
The `trading` program executes an atomic settlement instruction that resolves a matched order pair by distributing a match value ($V_{match}$) across four distinct stakeholders. The net proceeds for the seller ($P_{net}$) are defined by the deduction of protocol fees, infrastructure charges, and physical loss factors:

**5.1 Protocol Service Fee ($F$):**
$$F = \left\lfloor \frac{V_{match} \times \text{Fee}_{BPS}}{10,000} \right\rfloor$$

**5.2 Settlement Equation:**
$$P_{net} = V_{match} - F - C_{wheeling} - C_{loss}$$
Where $C_{wheeling}$ and $C_{loss}$ are dynamically injected parameters representing zone-aware infrastructure costs and physical resistive losses, respectively. This ensures that the physical realities of the power grid are reflected in the financial finality of the transaction.

### 6. Formal Model of Energy Tokenization and Issuance
The protocol transforms physical energy generation ($\Delta E$) into digital assets ($T_{mint}$) through a multi-stage validation and incentive pipeline. This process ensures that digital issuance is physically collateralized by verified telemetry.

**6.1 Incentive Distribution Function:**
The issuance is governed by a globally defined Feed-in-Tariff ($P_{FiT}$) and a dynamic, zone-specific incentive multiplier ($M_z$) retrieved from the on-chain `ZoneConfig`:
$$T_{mint} = \Delta E (\text{kWh}) \times P_{FiT} \times M_z$$
This model allows the DAO to programmatically incentivize generation in specific geographic shards without modifying the core minting program.

**6.2 Precision and Fixed-Point Representation:**
To maintain compatibility with the SPL Token standard and prevent rounding errors in high-frequency minting, the system scales the calculated issuance to 9 decimal places:
$$T_{lamports} = \lfloor T_{mint} \times 10^9 \rfloor$$

**6.3 Provenance and Co-signature Constraints:**
If the set of REC validators is non-empty ($N_{rec} > 0$), the `mint_tokens_direct` instruction enforces a cryptographic co-signature constraint:
$$\text{isValid}(\sigma_{rec}) \land \text{PubKey}(\sigma_{rec}) \in \{V_{rec,1} \dots V_{rec,5}\}$$
This ensures that every minted token is backed by a Renewable Energy Certificate (REC) verified by an authorized physical auditor.

**6.4 Deferred Supply Synchronization:**
To optimize for the Sealevel parallel execution engine, the `energy-token` program implements a deferred supply synchronization model. The `total_supply` state is decoupled from individual mint/burn operations to prevent write-lock contention:
$$S_{cached} \leftarrow S_{canonical} \text{ iff } \text{call}(\text{sync\_total\_supply})$$
This allows for massive horizontal scaling of minting operations across independent prosumer accounts.
