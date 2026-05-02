= System Architecture

GridTokenX is structured as a multi-layered ecosystem ensuring secure, auditable data flow from physical sensors to the decentralized exchange. The system follows the "Sync Core, Async Edges" principle: the critical settlement path is synchronous and strongly consistent, while edge data ingestion and analytics are handled asynchronously for maximum throughput.

== Architectural Layers

The platform is organized into four distinct layers, each with well-defined responsibilities and interfaces:

*Layer 1 — Physical Infrastructure (DePIN Layer)*: Comprises smart meters, EV chargers, battery management systems, and solar inverters. All devices communicate via standardized industrial protocols (DLMS/COSEM, OCPP 2.0.1, Modbus TCP) to Edge Gateways deployed at the prosumer premises.

*Layer 2 — Edge and Ingestion Layer*: Edge Gateways perform protocol translation, local data aggregation, and cryptographic signing before transmitting normalized telemetry to the cloud via mTLS-secured HTTP/2 tunnels. The Oracle Bridge service validates incoming data and publishes verified events to the messaging plane.

*Layer 3 — Service Mesh (Application Layer)*: A Kubernetes-orchestrated microservice mesh handles business logic including identity management, order matching, settlement orchestration, and analytics. Services communicate internally via ConnectRPC (HTTP/2 + Protobuf) and asynchronously via Kafka and NATS JetStream.

*Layer 4 — Blockchain Settlement Layer*: The Solana blockchain serves as the immutable settlement layer. The Chain Bridge service translates settlement intents from the application layer into signed Solana transactions, using HashiCorp Vault for non-exportable key management.

== Full System Service Map

The following diagram illustrates the interaction between the physical layer, service mesh, and the blockchain trust layer:

#figure(
  image("../figures/architecture.svg", width: 90%),
  caption: [The GridTokenX multi-layer architecture spanning DePIN hardware to Solana settlement.],
) <fig-arch>

== Service Inventory

The platform is composed of specialized microservices, each designed for a single responsibility and independently scalable:

#table(
  columns: (auto, auto, 1fr),
  inset: 8pt,
  align: (left, left, left),
  [*Service*], [*Protocol*], [*Responsibility*],
  [IAM Service], [ConnectRPC / gRPC], [User lifecycle, KYC verification, wallet linkage, RBAC enforcement, JWT issuance],
  [Trading Service], [ConnectRPC / Kafka], [CDA order book management, match execution, settlement intent publication],
  [Oracle Bridge], [HTTP/2 + mTLS], [IoT telemetry ingestion, Ed25519 signature verification, schema validation, Kafka publication],
  [Chain Bridge], [NATS JetStream], [Solana transaction construction, Vault-backed signing, broadcast and confirmation tracking],
  [Edge Gateway], [DLMS / OCPP / Modbus], [Protocol translation, local aggregation, hardware-signed payload generation],
  [gTHB Issuer], [ConnectRPC], [Stablecoin mint/burn lifecycle, reserve attestation, multisig coordination],
  [Analytics Service], [ClickHouse / HTTP], [Historical telemetry aggregation, prosumer reporting, market depth analytics],
  [Notification Service], [WebSocket / FCM], [Real-time event delivery to prosumer mobile and web clients],
)

== Data Flow and Protocols

=== Edge-to-Cloud Telemetry Flow

The telemetry pipeline is designed for high reliability and cryptographic auditability:

1. *Device Measurement*: A smart meter records a generation or consumption event (e.g., 0.25 kWh over a 15-minute interval). The Edge Gateway polls the meter via DLMS/COSEM and retrieves the signed meter reading.

2. *Edge Signing*: The Gateway constructs a JSON payload containing the device ID, timestamp (RFC 3339), energy value, and measurement unit. This payload is signed using the gateway's Ed25519 private key, which is stored in a hardware-backed secure enclave and never exposed in plaintext.

3. *Secure Transmission*: The signed payload is transmitted via HTTP/2 POST to the Envoy Proxy ingress, authenticated with a client TLS certificate issued by the platform's internal Certificate Authority (CA). The mTLS handshake ensures mutual authentication of both the gateway and the server.

4. *Oracle Bridge Processing*: The Oracle Bridge service receives the payload, verifies the Ed25519 signature against the device's registered public key (stored in the Solana Registry Program PDA), validates the JSON schema, and checks for duplicate submission (idempotency key). Valid events are published to the `energy.telemetry` Kafka topic with exactly-once semantics.

5. *Trading Service Consumption*: The Trading Service consumes telemetry events from Kafka, updates the prosumer's real-time energy balance, and triggers order matching if the prosumer has active sell orders.

=== Blockchain Write Path

On-chain operations follow a reliable, asynchronous pipeline:

1. *Intent Publication*: When the Trading Service determines that a match should be settled on-chain, it publishes a `SettlementIntent` message to the `chain.settlement` NATS JetStream subject. The intent includes all accounts, amounts, and pre-computed instruction data.

2. *Chain Bridge Processing*: The Chain Bridge service consumes the intent, constructs the Solana transaction with all required instructions (including the Ed25519 pre-verification instruction), and requests a signature from HashiCorp Vault using the platform's operator keypair. The private key never leaves the Vault HSM.

3. *Broadcast and Confirmation*: The signed transaction is broadcast to the Solana RPC cluster. The Chain Bridge monitors confirmation status and publishes a `SettlementConfirmed` or `SettlementFailed` event back to NATS, which the Trading Service uses to finalize or roll back the off-chain order state.

4. *Idempotency*: Each settlement intent carries a unique UUID that is recorded in a Solana Nullifier PDA upon successful execution. If the Chain Bridge retries a failed broadcast, the on-chain program rejects duplicate intents, preventing double-settlement.

== Messaging and Storage Planes

GridTokenX employs a polyglot persistence strategy, selecting the optimal storage technology for each data access pattern:

*Apache Kafka*: The backbone of the event-driven architecture. Used for ordered, durable event sourcing of all commands, market data, and audit logs. Kafka's log compaction ensures that the full history of every energy transaction is retained for regulatory compliance.

*NATS JetStream*: Used for low-latency, at-least-once delivery of settlement intents between the Trading Service and Chain Bridge. JetStream's consumer acknowledgment model ensures that no settlement intent is lost even during service restarts.

*PostgreSQL*: The primary transactional store for relational data including user accounts, KYC records, order history, and device registrations. Deployed with synchronous replication for high availability.

*Redis Cluster*: Provides sub-millisecond latency for session token validation, real-time order book caching, and market depth snapshots. Redis Streams are used for lightweight event fan-out to WebSocket notification clients.

*ClickHouse*: A columnar analytical database that ingests the full telemetry stream from Kafka for historical analysis. Supports prosumer energy dashboards, market analytics, and regulatory reporting with query latency in the hundreds of milliseconds over billions of rows.

*HashiCorp Vault*: Manages all cryptographic secrets including the platform operator keypair, TLS certificates, and database credentials. Vault's Transit Secrets Engine provides signing-as-a-service, ensuring private keys are never exposed to application code.

== Deployment and Scalability

The platform is deployed on Kubernetes with horizontal pod autoscaling (HPA) configured for all stateless services. The Oracle Bridge and Trading Service are the primary scaling bottlenecks and are designed to scale to 100+ replicas under load. Kafka partitioning is aligned with device zone IDs to ensure ordered processing within each grid zone while enabling parallel processing across zones.

The Edge Gateway software is distributed as a containerized application running on ARM-based or x86 industrial hardware, with over-the-air (OTA) update capability managed via a dedicated device management service.
