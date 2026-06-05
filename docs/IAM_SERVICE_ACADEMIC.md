# GridTokenX IAM Service: Identity and Access Management Architecture

**Abstract**
The `gridtokenx-iam-service` functions as the central identity, security, and authentication authority for the GridTokenX Platform. Implemented as a modular monolith, it enforces strict architectural boundaries to decouple domain logic from infrastructure constraints. This document details its layered architecture, unified identity model, communication protocols, and concurrency safeguards utilized to securely provision and validate access across the platform.

---

## 1. Introduction

Identity and Access Management (IAM) requires resilient, high-throughput verification without compromising domain complexity. The GridTokenX IAM Service establishes a definitive boundary for user lifecycles, Role-Based Access Control (RBAC), and session management. It acts as the authoritative bridge between off-chain user states (managed via traditional web paradigms) and on-chain cryptographic identities (managed via the Solana Registry program).

## 2. Architectural Design: Modular Monolith

The service adheres to the **"Sync Core, Async Edges"** architectural principle, structuring the Rust workspace into distinct crates to enforce a downward dependency flow. 

### 2.1 Crate Topology
- **`iam-core`**: The foundational primitive layer containing zero-dependency domain models, common error types, and trait definitions.
- **`iam-protocol`**: The contract layer defining domain-agnostic Protobuf schemas and generated ConnectRPC implementations.
- **`iam-persistence`**: The infrastructure layer handling state mutations via SQLx (PostgreSQL), Redis, and Kafka/RabbitMQ.
- **`iam-logic`**: The domain core orchestrating business rules (e.g., `AuthService`). It is decoupled from implementation details via Trait-Based Dependency Injection.
- **`iam-api`**: The asynchronous edge adapter defining high-concurrency Axum REST endpoints and ConnectRPC handlers.
- **`bin/iam-service`**: The executable entry point responsible for configuration loading and the orchestration of Dependency Injection.

### 2.2 Trait-Based Dependency Injection
The `iam-logic` layer interacts with external services exclusively through traits defined in `iam-core`. This enables comprehensive unit testing (via `mockall`) and permits the substitution of infrastructure components without altering business rules. To resolve complex lifetime constraints across crate boundaries, the service utilizes manual `BoxFuture` return types for specific interfaces (e.g., `BlockchainTrait`).

## 3. Unified Identity Model and Cryptography

The system provisions dual identities upon user registration:
1.  **Off-Chain Identity:** Persistent relational data stored in PostgreSQL. Passwords are secured using Argon2id hashing algorithms.
2.  **On-Chain Identity:** A Program Derived Address (PDA) deterministically derived and registered on the Solana blockchain via the platform's Registry program. 

This model links traditional authentication flows with decentralized cryptographic authorities.

## 4. Protocol and Communication Topologies

The IAM service is the authoritative verification node for inter-service communications, operating on dual protocols.

### 4.1 Inter-Service Verification (ConnectRPC)
Internal microservices rely on the IAM service to validate incoming requests facilitated via high-throughput gRPC over HTTP/2 (`ConnectRPC`).
*   `VerifyToken`: Validates JWT cryptographic signatures, expiry, and queries the Redis session cache.
*   `Authorize`: Evaluates RBAC constraints for downstream services.

### 4.2 Client-Facing Access (REST)
External consumers interact with the IAM service through a standard JSON REST API routed via the system's API Gateway. This pathway handles user registration, login, and profile management.

## 5. Concurrency and System Safety

To maintain high throughput, the service implements rigorous concurrency safeguards.

### 5.1 Tokio Worker Starvation Prevention
The service segregates I/O-bound operations from CPU-bound operations. Cryptographic tasks—such as Argon2id password hashing and JWT signature generation—are offloaded from the primary asynchronous executor using `tokio::task::spawn_blocking`. This ensures consistent low-latency request handling under load.

### 5.2 Idempotency and Fault Tolerance
State-mutating persistence operations (`iam-persistence`) are designed to be idempotent. This ensures that the system can safely retry operations during partial network failures without compromising the integrity of the off-chain Postgres store or the on-chain Solana state.

## 6. Conclusion

The `gridtokenx-iam-service` exemplifies a disciplined approach to identity management in hybrid Web2/Web3 environments. Its modular monolithic architecture ensures clean domain separation, and its unified identity model successfully bridges the gap between traditional web authentication and cryptographic blockchain identity.
