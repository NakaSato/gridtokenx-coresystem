# GridTokenX Notification Service: Omni-Channel Dispatch Architecture

**Abstract**
The `gridtokenx-noti-service` serves as the centralized, stateful notification dispatcher for the GridTokenX platform. Designed to handle high-throughput outbound communications, it supports omni-channel delivery (Email, WebSockets) while providing idempotency and robust fault tolerance through exponential backoff retry disciplines. This document outlines the system's modular monolithic architecture, its adherence to "Sync Core, Async Edges" principles, and the mechanisms by which it reliably converts asynchronous platform events into user communications.

---

## 1. Introduction

In distributed energy platforms, timely delivery of transactional alerts (e.g., trade matching, account onboarding) is critical for system usability. The GridTokenX Notification Service acts as a resilient message sink and omni-channel dispatcher. By decoupling the core orchestration logic from infrastructure specificities using a hexagonal ports-and-adapters architecture, the service achieves high testability and deterministic performance under concurrent load.

## 2. Architectural Design

The service is constructed as a **Modular Monolith** employing a 6-crate Rust workspace. The design rigorously enforces an acyclic dependency flow, ensuring that network adapters cannot leak implementation details into the domain core.

### 2.1 Crate Topology
- **`noti-core`**: The foundational primitive layer containing zero-I/O domain models, error enumerations, and core Dependency Injection (DI) traits.
- **`noti-protocol`**: The contract layer encompassing ConnectRPC (gRPC) definitions generated from Protobuf schemas.
- **`noti-persistence`**: The concrete infrastructure layer implementing SQLx (PostgreSQL), Redis (caching and locks), RabbitMQ (dispatch/retry queues), Kafka (event consumption), and SMTP/WebSocket providers.
- **`noti-logic`**: The pure domain core containing the `NotificationOrchestrator`, determining queuing, provider selection, and retry disciplines exclusively via `noti-core` traits.
- **`noti-api`**: The high-concurrency adapter layer providing Axum REST endpoints, ConnectRPC handlers, and the real-time WebSocket connection registry.
- **`bin/noti-server`**: The application entry point responsible for environment configuration and orchestrating DI wiring.

### 2.2 Sync Core, Async Edges
The architecture segregates I/O bounds. The orchestrator makes synchronous branching decisions regarding idempotency state and retry backoffs, delegating the actual asynchronous I/O execution to the trait implementations in the persistence layer.

## 3. Message Delivery Mechanics

The Notification Service acts as a Kafka consumer, processing domain events from `iam.user.events` and `iam.audit.events` into formatted outbound communications.

### 3.1 Idempotency and Deduplication
Upon receiving an event, the orchestrator performs a distributed lock check via Redis. This prevents concurrent redeliveries of the same Kafka event from resulting in duplicate dispatches, ensuring exact-once processing semantics at the orchestration boundary.

### 3.2 RabbitMQ Dead-Letter Exchange (DLX) Retry Strategy
To provide resilient delivery against downstream provider outages, the system employs a RabbitMQ retry topology:
1. Failed dispatches are routed to a `noti.retry` queue.
2. The retry queue utilizes an `x-dead-letter-exchange` pointing back to the main dispatch routing key.
3. The orchestrator applies an exponential backoff algorithm attaching the delay as an expiration header (TTL) before requeuing.

### 3.3 Dynamic Template Rendering
Message bodies are dynamically generated using the `Tera` templating engine, providing HTML auto-escaping. The system supports multi-part MIME email composition, generating plaintext fallbacks to ensure broad client compatibility.

## 4. Concurrency and Dual Server Topology

The service concurrently operates dual network listeners sharing a unified Axum router:
- **HTTP/REST (TCP):** Exposes endpoints for polling notification history and WebSocket session negotiation.
- **gRPC/ConnectRPC (TCP/HTTP2 + UDP/QUIC):** Utilizing `quinn` and `h3`, it exposes remote procedure calls over HTTP/3 for internal service communication.

Database queries are bifurcated utilizing a **Dual PostgreSQL Pool** strategy. High-priority connection pools handle state mutations (writes), while constrained low-priority pools serve client reads, preventing reporting queries from starving the dispatch pipeline.

## 5. Conclusion

The `gridtokenx-noti-service` represents a robust notification architecture designed for grid-scale environments. By combining acyclic hexagonal architecture, strict idempotency guarantees, and an advanced RabbitMQ DLX retry mechanism, it provides an omni-channel dispatch system capable of high concurrency and reliable message delivery.
