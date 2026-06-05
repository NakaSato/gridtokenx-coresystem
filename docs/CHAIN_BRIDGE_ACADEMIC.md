# GridTokenX Chain Bridge: Decentralized Signing Authority Architecture

**Abstract**
The `gridtokenx-chain-bridge` microservice acts as the exclusive gateway and decentralized signing authority between GridTokenX off-chain services and the Solana blockchain. By implementing a strict Reference Monitor pattern, it decouples transaction construction from cryptographic signing. This document details the architectural topology, authorization invariants, and integration with SPIFFE-based workload identity and HashiCorp Vault Transit.

---

## 1. Introduction

In modern decentralized architectures, managing private key material across distributed microservices introduces operational risks. The GridTokenX Chain Bridge resolves this by centralizing the interaction with the Solana blockchain into a single mediated perimeter. Backend services do not hold private keys; instead, all signing is delegated to a hardened signing oracle. This design ensures that every transaction is authenticated, authorized, and structurally validated before submission.

## 2. Theoretical Foundations

### 2.1 The Reference Monitor Pattern

The Chain Bridge implements a mediated Reference Monitor pattern characterized by:
1. **Tamper-proof Environment:** The mediation mechanism operates within a hardened network perimeter, with entry points secured via mutual TLS (mTLS).
2. **Always-invoked Path:** Every transaction path (synchronous gRPC and asynchronous NATS JetStream) converges at an atomic `sign_and_submit()` pipeline.
3. **Focused Verification Area:** The core authorization logic (RBAC mapping and Policy Engine validation) and the signing delegation are concentrated in an auditable surface area.

### 2.2 Root of Trust (RoT) Partitioning

The system operates under a Delegated Trust Model, partitioning authority to minimize systemic risks:
* **Identity RoT (SPIFFE):** Workload identity is rooted in the platform's SPIRE control plane. The bridge relies on the verification of X.509 SVIDs during the TLS handshake.
* **Key RoT (Vault Transit):** Cryptographic keys are not instantiated in the application's address space. The bridge delegates signing to HashiCorp Vault.
* **Blockchain RoT (Solana):** Finality and state transitions are rooted in the Solana validator cluster.

## 3. Formal System Invariants

The Chain Bridge maintains the following properties during operation:

### 3.1 Authorization Integrity
A signature for a transaction is generated only if the mediation function (involving identity verification, RBAC, and policy constraints) succeeds.

### 3.2 Transaction Processing
Valid transactions submitted by an authorized identity reach the blockchain layer within the blockhash validity window (approximately 60s), facilitated by an asynchronous pull-based consumer with retry disciplines.

### 3.3 Identity Non-Repudiation
Identities are derived directly from the verified transport layer ($L_4$) Subject Alternative Name (SAN) URI, mitigating application-layer ($L_7$) spoofing vectors.

## 4. Architectural Topology

The bridge ingests transactions via two distinct topological paths, converging at a unified processing pipeline.

### 4.1 Dual Ingestion Paths
1. **Synchronous RPC (gRPC / ConnectRPC):** Utilized for real-time transaction submission and state queries by services such as the Trading Service and Oracle Bridge.
2. **Asynchronous Messaging (NATS JetStream):** Utilized for batch settlement and retry queues, implementing a concurrent pull consumer to maximize throughput.

### 4.2 The Atomic `sign_and_submit` Pipeline
All transactions must clear the core pipeline:
1. **Deserialization:** Payload decoded into a Solana `Transaction`.
2. **Policy Engine Evaluation:** Ensures program IDs invoked align with the caller's allowed list.
3. **Blockhash Cache Injection:** Ameliorates RPC latency by injecting a cached latest blockhash if needed.
4. **Delegated Signing:** Vault Transit signs the raw message data.
5. **Signature Attachment:** The resulting Ed25519 signature is affixed to the transaction.
6. **Network Submission:** Broadcast to the Solana validator network.

## 5. Defense in Depth Mechanisms

The implementation provides an overlapping defense mechanism:
1. **Network Layer:** Strict mTLS via `WebPkiClientVerifier`.
2. **Identity Layer:** SPIFFE URIs cryptographically extracted via `PeerCertLayer`.
3. **RBAC Layer:** Per-RPC endpoint method assertions mapping SPIFFE identities to `ServiceRole` categories.
4. **Policy Layer:** Instruction-level Program ID allowlisting.
5. **Key Authority:** Remote signing via Vault Transit; zero local key instantiation.
6. **Idempotency:** A concurrent `DashMap` cache actively rejects double-submissions.
7. **Staleness Protection:** A 55-second TTL validation rejects expired payloads prior to signing.
8. **Retry Discipline:** Bound retries (max 3 attempts) restrict transient RPC amplification.

## 6. Conclusion

The `gridtokenx-chain-bridge` establishes a robust, zero-trust boundary between distributed microservices and the Solana Virtual Machine. By enforcing strict reference monitoring and delegating cryptographic operations to key management systems, the architecture ensures authorization integrity and high operational reliability.
