# Layered System Architecture: A Cyber-Physical System Design for Decentralized P2P Energy Markets

## Abstract
This document details the layered cyber-physical architecture of the GridTokenX platform. To address the computational limits of distributed ledgers and the latency constraints of high-frequency internet of things (IoT) telemetry, we present a four-layered system model. By decoupling edge protocol translation, off-chain cryptographic signature verification, event-sourced matching, and on-chain atomic settlement, the architecture achieves low-latency, trustless, and grid-aware energy transactions.

---

## 1. Architectural System Model

The GridTokenX system model is formalized as a four-tier architecture designed to bridge the physical electricity grid with a decentralized ledger. The structure minimizes on-chain storage and execution overhead while preserving non-repudiation and security invariants. For a detailed mapping of data movement across services, see the [Data Flow Documentation](DATA_FLOW.md).

```
+---------------------------------------------------------------------------------+
|                             I. SMARTMETER SIMULATOR                             |
|  [Smart Meter Node] ---> Compute Ed25519 Signature: Sig = sign(SK_edge, Payload)  |
+------------------------------------+--------------------------------------------+
                                     │
                                     ▼ (Secure TLS Tunnel)
+------------------------------------+--------------------------------------------+
|                       II. INGESTION & MIDDLEWARE LAYER                         |
|  [Oracle Bridge] ───► Verify: verify(PK_edge, Payload, Sig)                    |
|         │                                                                       |
|         ▼ (Partitioned by Meter ID)                                             |
|  [Apache Kafka Event Log] ───► Event-Sourced Storage                            |
+------------------------------------+--------------------------------------------+
                                     │
                                     ▼ (Kafka Event Stream Ingestion)
+------------------------------------+--------------------------------------------+
|                       III. EXCHANGE PLATFORM LAYER                             |
|  [Continuous Double Auction Engine]                                             |
|         │                                                                       |
|         ▼ (Generate Match Payload with Match Engine Signature)                 |
|  [Atomic Settlement Gateway]                                                    |
+------------------------------------+--------------------------------------------+
                                     │
                                     ▼ (Anchor RPC Call)
+------------------------------------+--------------------------------------------+
|                          IV. DISTRIBUTED LEDGER LAYER                           |
|  [Solana Virtual Machine Program Space]                                         |
|    ├── Registry Program (Wallet-to-Node Mapping)                                |
|    ├── Settlement Program (Multi-Signature Validation & Escrow Clearing)         |
|    └── Energy Asset Ledger (SPL Token Minting & Transfer)                       |
+---------------------------------------------------------------------------------+
```

---

## 2. Layer Analysis

### A. SmartMeter Simulator Layer
The SmartMeter Simulator layer simulates physical smart meters to generate telemetry and interface with the electrical network structure.
1. **Telemetry Generation:** Each simulated smart meter node directly generates measurements (active/reactive power, voltage, current, frequency) or imports them via historical load profile playback, packaging them into standardized JSON frames or raw binary payloads.
2. **Cryptographic Attestation:** To establish data integrity at the source, the smart meter signs each telemetry frame using an asymmetric **Ed25519** signature scheme. Depending on the ingestion path, the signing target is either:
   * **Text Path:** A structured colon-separated string: `"{meter_id}:{surplus_energy}:{timestamp_seconds}"`.
   * **Binary Path:** A binary encoded DLMS/COSEM frame representation.
   The private key ($SK_{edge}$) is stored inside the meter's configuration to prevent unauthorized manipulation.

### B. Ingestion & Middleware Layer
To prevent malicious nodes from exhausting blockchain resources through Sybil attacks or malformed payloads, the ingestion layer enforces off-chain input filtering.
1. **Ingestion Transport Interfaces:** The Oracle Bridge exposes dual-path reception protocols:
   * **gRPC / ConnectRPC Interface:** High-throughput RPC endpoint that accepts structured `TelemetryRequest` protobuf payloads. In binary mode, raw DLMS/COSEM frames are transmitted directly as a byte stream to eliminate JSON serialization latency.
   * **HTTP REST Interface:** Standard web API endpoint that accepts JSON structured payloads (e.g., `POST /api/v1/telemetry/submit-reading`) for compatibility with legacy systems or REST-only clients.
2. **Oracle Bridge Signature Verification:** The Oracle Bridge serves as a stateless validator. Upon receiving a payload from either transport path, it performs a cryptographic lookup against an in-memory cache of registered public keys ($PK_{edge}$). It verifies the signature:
   $$\text{verify}(PK_{edge}, \text{Payload}, \text{Sig}) == \text{True}$$
   Invalid or unregistered inputs are dropped immediately at the boundary.
3. **Message Partitioning & Event Sourcing:** Authenticated telemetry frames are forwarded to a partitioned **Apache Kafka** topic. To guarantee monotonic time ordering per physical node, payloads are partitioned using the unique `meter_id` as the message key.

### C. Exchange Platform Layer
The Exchange Platform contains the high-frequency matching components and the business logic gateways.
1. **API Routing Proxy:** A gRPC-enabled gateway manages authorization, rate limiting, and request serialization using **ConnectRPC** over HTTP/2.
2. **Matching Engine (Continuous Double Auction):** The matching service consumes the telemetry stream and tracks the energy states of active nodes. Buy and sell orders are matched in real-time based on price-time priority. When a match occurs, the matching engine generates a cryptographic match proof, signing it with the matching engine's key ($SK_{match}$).

### D. Distributed Ledger Layer
The ultimate source of state and financial settlement is executed on the **Solana** blockchain using smart contracts built with the **Anchor** framework.
1. **On-Chain Meter Registry:** To prevent wallet-spoofing, the registry program maintains a state mapping:
   $$\text{RegistryAccount} \rightarrow \{ \text{OwnerWallet}, \text{MeterID}, \text{FeederNodeID} \}$$
   This binds a cryptographic identity to a physical location on the grid topology.
2. **Atomic Settlement Program:** Settles matched trades on-chain. It accepts the match payload, verifies the signature of the matching engine, and executes an atomic transfer:
   * It transfers stablecoins (e.g., USDC) from the buyer's on-chain escrow to the seller.
   * It mints and transfers **SPL Energy Tokens** to the buyer, representing cryptographic, non-repudiable utility certificates of green energy delivery.

---

## 3. End-to-End Transaction Lifecycle

1. **Telemetry Generation & Signing:** 
   * **Structured Text Format:**
     $$\text{Data}_{\text{text}} = \text{MeterID} \mathbin{\Vert} \text{SurplusEnergy}_{\text{kWh}} \mathbin{\Vert} \text{Timestamp}_{\text{seconds}}$$
   * **Binary DLMS Format:**
     $$\text{Data}_{\text{bin}} = \text{DLMS\_Payload}$$
   * **Signature Computation:**
     $$\text{Sig} = \text{Sign}(SK_{\text{edge}}, \text{Data})$$
2. **Off-Chain Verification:** Oracle Bridge verifies $\text{Sig}$ using $PK_{\text{edge}}$, and commits the validated state to the Kafka ingestion log.
3. **Auction Matching:** The matching engine matches the seller's surplus with the buyer's deficit and outputs a match result signed by the engine:
   $$\text{Match} = \{ \text{Buyer}, \text{Seller}, \text{Volume}_{\text{kWh}}, \text{Price}_{\text{USDC}} \}$$
4. **On-Chain Settlement:** The settlement smart contract verifies the matching engine's signature, transfers USDC, and mints the SPL Energy token to the buyer.
5. **Auditing & State Logging:** The settlement program emits an on-chain transaction log, facilitating trustless audits by distribution system operators (DSOs).
