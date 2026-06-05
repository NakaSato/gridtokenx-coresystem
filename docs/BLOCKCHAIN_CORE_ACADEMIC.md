# GridTokenX Blockchain Core: Architecture and Design Formalisms

**Abstract**
The `gridtokenx-blockchain-core` library constitutes the foundational middleware and shared cryptographic primitives for the GridTokenX microservices ecosystem. It establishes a unified security model for cross-service authentication, authorization, and blockchain interaction. This document outlines the architecture, security mechanisms, and system abstractions implemented within the core library.

---

## 1. Introduction

In decentralized financial infrastructures, the interaction between off-chain microservices and on-chain smart contracts presents a critical operational surface. `gridtokenx-blockchain-core` addresses this by centralizing critical access controls, messaging schemas, and identity verification into a strictly typed shared library. By adopting an architecture rooted in SPIFFE (Secure Production Identity Framework for Everyone) and Role-Based Access Control (RBAC), the core library ensures that transactions are authenticated and contextually authorized before reaching the signing authority (`chain-bridge`).

## 2. Architectural Abstractions

The core library is partitioned into several interoperable modules, each addressing a specific domain of the system architecture.

### 2.1 Identity and Authorization (`auth.rs`)

The identity model leverages X.509 SVIDs (SPIFFE Verifiable Identity Documents) injected during mutual TLS (mTLS) handshakes. The `auth::SpiffeIdentity` struct acts as the canonical representation of a caller's identity.

A deterministic mapping translates a SPIFFE URI into a domain-specific `ServiceRole`:
`spiffe://gridtokenx.th/prod/trading-service/api` → `TradingApi`

This mapping reduces the reliance on application-layer HTTP headers, grounding the identity in the transport layer's cryptographic proofs.

### 2.2 Policy Enforcement Engine (`policy.rs`)

The `PolicyEngine` implements a Reference Monitor pattern to prevent unauthorized program invocation. It defines an instruction-level validation function against the SPIFFE Identity and the Solana Transaction.

Let `P` be the set of all Solana Program IDs and `A(I)` be the subset of programs authorized for identity `I`. The validation requires that for all instructions in the transaction, the program ID must belong to the authorized set or the System Program. For instance, the `TradingMatcher` identity is explicitly permitted to invoke the Trading, Registry, and Energy Token programs, but denied access to the Oracle program. This compartmentalization bounds the operational scope of each microservice.

### 2.3 RPC and Messaging Middleware (`rpc/`)

The `rpc` module defines the structural boundaries for both synchronous and asynchronous inter-process communication:
1. **gRPC Definitions:** Trait bounds (e.g., `BlockchainService`, `TransactionHandler`) ensure that consuming services implement a standardized interface for interacting with the ledger.
2. **NATS JetStream Schemas:** Defines deterministically serialized message formats (e.g., `TxSubmitMessage`, `TxResultMessage`) required for the asynchronous transaction ingestion paths. This provides binary compatibility across the message bus.

## 3. Security Model

The security posture of the GridTokenX ecosystem relies on primitives defined in `blockchain-core`.

### 3.1 Role-Based Access Control (RBAC)

The `ServiceRole` enum enforces access constraints natively within the Axum routing layer via the `FromRequestParts` trait. The `require()` and `require_any()` functions ensure that specific RPC endpoints are accessible only by the provided roles.

### 3.2 Program-Level Isolation

By evaluating transaction payloads prior to signing, the core library mitigates the risk of unauthorized code execution on the Solana Virtual Machine (SVM). The evaluation of instructions against the hardcoded `SolanaProgramsConfig` enforces strict least-privilege adherence.

## 4. Empirical Validation

The robustness of the core library is validated through extensive testing:
- **Identity Resolution:** Assertions mapping SPIFFE URIs to expected `ServiceRole` enumerations.
- **Policy Enforcement:** Tests demonstrating that a valid identity attempting to construct an unauthorized transaction payload results in a deterministic rejection.
- **RBAC Assertions:** Matrix testing of role-based permissions against simulated API endpoints.

## 5. Conclusion

The `gridtokenx-blockchain-core` library provides the indispensable security and communication scaffolding for the GridTokenX platform. Through its implementation of SPIFFE-based identity mapping, RBAC enforcement, and instruction-level transaction validation, it establishes a resilient and well-defined interface between off-chain services and the Solana blockchain.
