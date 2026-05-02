= Security Analysis and Provenance

GridTokenX implements a "Defense-in-Depth" security strategy across all layers of the stack. This section provides a comprehensive analysis of the threat model, attack vectors, and corresponding mitigations.

== Threat Model

The platform's threat model considers four categories of adversaries:

*External Attackers*: Malicious actors with no privileged access attempting to exploit network-facing services, smart contracts, or the blockchain layer.

*Compromised Devices*: Edge Gateways or smart meters that have been physically tampered with or whose software has been compromised.

*Malicious Insiders*: Platform operators or service accounts attempting to manipulate market data, steal user funds, or issue fraudulent tokens.

*Economic Attackers*: Sophisticated actors attempting to manipulate market prices, exploit smart contract logic, or destabilize the gTHB peg through large-scale coordinated trading.

== Layer 1: Physical and Edge Security

=== Hardware Tamper Protection

Edge Gateways are housed in tamper-evident enclosures with physical intrusion detection sensors. Upon detection of physical tampering:
1. The HSM immediately zeroizes all stored private keys.
2. The gateway transmits a tamper alert to the platform's device management service.
3. The device's certificate is revoked via OCSP, preventing further data submission.
4. The IAM Service flags the associated prosumer account for manual review.

This ensures that even if an attacker gains physical access to a gateway, they cannot extract the signing key or submit fraudulent readings using the device's identity.

=== Anomaly Detection

The Oracle Bridge implements statistical anomaly detection for incoming telemetry:
- *Capacity Bounds Check*: Readings exceeding 110% of the device's rated capacity are flagged and quarantined for manual review.
- *Temporal Consistency Check*: Energy readings must be monotonically increasing (for cumulative meters). Decreasing readings indicate meter tampering or rollover.
- *Peer Comparison*: Readings from a device are compared against neighboring devices in the same zone. Significant deviations (>3σ from zone average) trigger an alert.
- *Velocity Check*: Sudden spikes in generation (e.g., 10× normal output) are flagged as potentially fraudulent.

Flagged readings are not published to Kafka and do not trigger token minting until cleared by a human reviewer or automated re-validation.

== Layer 2: Network and Transport Security

=== mTLS Everywhere

All network communication within the GridTokenX platform uses mutual TLS (mTLS):
- *Edge-to-Cloud*: Edge Gateways authenticate with client certificates issued by the platform CA.
- *Service-to-Service*: All microservices authenticate with service certificates managed by cert-manager and rotated every 90 days.
- *External APIs*: Public-facing APIs use standard TLS with certificate pinning in the mobile application.

=== DDoS Protection

The Envoy Proxy ingress implements rate limiting at multiple levels:
- *Per-Device Rate Limit*: Maximum 1 telemetry submission per 30 seconds per device (configurable per device type).
- *Per-IP Rate Limit*: Maximum 100 requests per second per source IP.
- *Global Rate Limit*: Circuit breaker that activates if total ingress exceeds 10,000 requests per second, protecting downstream services.

=== Network Segmentation

The platform is deployed in a Kubernetes cluster with strict NetworkPolicy rules:
- Edge-facing services (Envoy Proxy, Oracle Bridge) are isolated in a dedicated namespace with no direct access to the database tier.
- The Chain Bridge has no inbound network access — it only makes outbound connections to Solana RPC nodes and HashiCorp Vault.
- Database services are accessible only from their designated application services.

== Layer 3: Application and Smart Contract Security

=== Ed25519 Cross-Instruction Verification

The most critical security mechanism in the on-chain settlement layer is the use of Solana's `instructions` sysvar for cross-instruction Ed25519 signature verification. This prevents unauthorized settlement in the following way:

When the Chain Bridge constructs a `match_orders` transaction, it prepends an `Ed25519Program.createInstructionWithPublicKey` instruction for each order being settled. This instruction verifies that the order payload (containing order ID, price, quantity, and expiry) was signed by the order creator's private key.

The `match_orders` instruction then reads the `instructions` sysvar to confirm that the required Ed25519 verification instructions are present and that the verified public keys match the order creators' registered wallet addresses. If any verification is missing or fails, the entire transaction is rejected.

This mechanism ensures that:
1. Only the legitimate order creator can authorize settlement of their order.
2. The order parameters cannot be modified between signing and settlement.
3. A compromised Chain Bridge cannot settle orders without valid user signatures.

=== Nullifier-Based Replay Protection

Every settled order generates a `Nullifier` PDA with the order UUID as the seed. The `match_orders` instruction checks for the existence of this PDA before processing. If the PDA already exists, the instruction returns a `OrderAlreadySettled` error.

This prevents replay attacks where an attacker captures a valid settlement transaction and rebroadcasts it to drain funds. Even if the same signed order payload is submitted multiple times, only the first settlement succeeds.

=== Smart Contract Audit Trail

All on-chain programs have undergone independent security audits by recognized Solana security firms. Audit reports are published publicly and referenced on-chain via IPFS content hashes stored in the `ProtocolConfig` PDA. The platform maintains a bug bounty program with rewards up to \$500,000 for critical vulnerabilities.

=== Integer Overflow Protection

All arithmetic in on-chain programs uses Rust's checked arithmetic operations (`checked_add`, `checked_mul`, `checked_div`). Any overflow or underflow returns an error rather than wrapping, preventing economic exploits based on integer overflow.

=== Account Validation

Every instruction handler validates all input accounts using Anchor's constraint system:
```rust
#[account(
    mut,
    seeds = [b"meter_state", device_id.as_ref()],
    bump = meter_state.bump,
    constraint = meter_state.device_id == device_id @ ErrorCode::DeviceMismatch,
)]
pub meter_state: AccountLoader<'info, MeterState>,
```

This prevents account substitution attacks where an attacker passes a malicious account in place of a legitimate one.

== Layer 4: Key Management and HSM Security

=== HashiCorp Vault Architecture

The platform's cryptographic key management is centralized in HashiCorp Vault, deployed in a high-availability configuration across three availability zones:

- *Solana Operator Key*: Stored in Vault's Transit Secrets Engine. The Chain Bridge requests signatures via the Transit API — the private key never leaves Vault.
- *gTHB Multisig Keys*: Each of the 5 multisig participants holds their key in a separate Vault instance or hardware HSM. Signing requires 5 independent API calls to 5 separate Vault instances.
- *TLS Certificates*: Managed by Vault's PKI Secrets Engine, with automatic rotation.
- *Database Credentials*: Managed by Vault's Database Secrets Engine, with dynamic credential generation and automatic rotation every 24 hours.

=== gTHB Multisig Security

The gTHB stablecoin's mint and burn operations currently require a 5-of-9 multisig. The 9 signers are:
- 3 GridTokenX team members (geographically distributed)
- 3 independent board members
- 3 institutional custodians

Each signer holds their key in a hardware HSM. While this arrangement provides strong security guarantees, it introduces a latency bottleneck that is architecturally inconsistent with the sub-400ms settlement finality achieved elsewhere in the stack: coordinating 5 independent signers across time zones imposes delays of minutes to hours, and large-volume mints have historically required synchronous coordination ceremonies.

*Planned Improvement — Programmable MPC Custody*: The roadmap targets replacing the static multisig with a threshold Multi-Party Computation (MPC) signing pipeline. Under this model, signing shares are held by geographically distributed nodes running a threshold signature scheme (e.g., FROST or GG20). Routine mints below a configurable threshold (e.g., 1,000,000 gTHB) are processed fully automatically once bank deposit confirmation and KYC/AML checks pass, with no human coordination required. Large institutional mints above the threshold trigger an asynchronous approval workflow where signers respond via authenticated mobile push rather than in-person ceremony. Reserve attestations remain continuous and on-chain regardless of mint size, preserving auditability while eliminating the synchronous bottleneck.

== Layer 5: Monitoring and Incident Response

=== Real-Time Security Monitoring

The platform operates a 24/7 Security Operations Center (SOC) with:
- *On-Chain Monitoring*: Automated alerts for unusual transaction patterns (e.g., large single-block settlements, unusual account drains).
- *Off-Chain Monitoring*: SIEM integration with alerts for failed authentication attempts, anomalous API access patterns, and infrastructure anomalies.
- *Smart Contract Event Monitoring*: All on-chain events are indexed and monitored for anomalies using a dedicated blockchain analytics service.

=== Incident Response

The platform maintains a documented incident response plan with defined severity levels and response times:
- *Critical (P0)*: Active fund drain or peg break. Response time: 15 minutes. Actions: Emergency circuit breaker activation, multisig freeze.
- *High (P1)*: Confirmed vulnerability with no active exploit. Response time: 4 hours. Actions: Coordinated disclosure, patch deployment.
- *Medium (P2)*: Anomalous behavior under investigation. Response time: 24 hours.
