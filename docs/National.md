# GridTokenX System Architecture

This document describes the actual system architecture and deployment topology of the GridTokenX platform as implemented in the current codebase.

## High-Level Topology

The system is designed around a microservices architecture communicating via REST, gRPC, and asynchronous message brokers. All components are containerized and orchestrated via Docker Compose for local development and testing.

```text
[ EXTERNAL CLIENTS / DEVICES ]
          | (HTTPS / mTLS)
          v
+--------------------------------------------------------+
| EDGE & API GATEWAYS                                    |
| - APISIX (User Proxy / Web Clients)                    |
| - Envoy  (IoT Edge Proxy / mTLS)                       |
+--------------------------------------------------------+
          |
          v
+--------------------------------------------------------+
| CORE MICROSERVICES (Rust)                              |
| - IAM Service (Identity, Auth, JWT)                    |
| - Trading Service (Matching, Settlement, Order Book)   |
| - Oracle Bridge (IoT Telemetry Ingestion)              |
| - Notification Service (Email, Alerts)                 |
+--------------------------------------------------------+
          |
          v
+--------------------------------------------------------+
| BLOCKCHAIN INTERFACE (Rust)                            |
| - Chain Bridge (Vault-backed Signing & Submission)     |
+--------------------------------------------------------+
          | (RPC)
          v
[ SOLANA LOCALNET / DEVNET ]
```

## Core Components

### 1. API & Edge Gateways
- **Apache APISIX (`apisix`)**: Handles public internet traffic for web clients (e.g., `trading-ui`). Routes requests to appropriate microservices.
- **Envoy (`envoy`)**: Edge gateway primarily designed for IoT device ingestion, terminating mTLS connections from smart meters.

### 2. Microservices
- **IAM Service (`gridtokenx-iam-service`)**: Manages user identities, API keys, JWT authentication, and off-chain wallet authority mapping.
- **Trading Service (`gridtokenx-trading-service`)**: The core engine containing the order matcher, settlement logic, and trading API. Connects to Redis for caching/streaming and Postgres for state persistence.
- **Oracle Bridge (`gridtokenx-oracle-bridge`)**: Receives telemetry data (e.g., from `gridtokenx-smartmeter-simulator`), validates device signatures, and pushes events into the internal message bus for settlement.
- **Notification Service (`gridtokenx-noti-service`)**: Handles async delivery of emails and platform alerts.

### 3. Messaging & Streaming
The platform uses a segmented approach to message routing to isolate different traffic profiles:
- **Kafka Cluster (Command)**: Durable, strictly ordered queue for critical commands.
- **Kafka Cluster (Market)**: High-throughput, ephemeral stream for market data and telemetry.
- **Kafka Cluster (Audit)**: Long-retention queue for regulatory and system audit events.
- **RabbitMQ**: Handles asynchronous task queuing and RPC-style service-to-service communication.
- **Redis Streams**: Used for fast, transient event dissemination (e.g., between Oracle Bridge and Trading Service).

### 4. Persistence Tier
- **PostgreSQL**: Primary transactional store for all services. Implemented with primary and read-replica (including cascading replica) nodes. Connection pooling is managed by PgBouncer.
- **Redis**: Caching layer for IAM and Trading services, and transient event streams.
- **ClickHouse**: OLAP database used for high-volume analytics and trade history.
- **InfluxDB**: Time-series database for raw smart meter telemetry persistence.
- **MinIO**: S3-compatible object storage for cold data and large payloads.

### 5. Blockchain Integration
- **Chain Bridge (`gridtokenx-chain-bridge`)**: The exclusive gateway to the Solana network. No microservice holds private keys. Instead, they send transaction requests via gRPC or NATS to the Chain Bridge, which delegates signing to a HashiCorp Vault Transit engine before submitting the transaction to Solana. Enforces SPIFFE-based identity mapping and program-level RBAC.
- **Vault (`vault`)**: HashiCorp Vault instance providing the Transit Secrets Engine for Ed25519 transaction signing.

### 6. Observability
- **Prometheus & Grafana**: System metrics collection and visualization.
- **Node Exporter & cAdvisor**: Host and container-level resource metrics.

## Logical Flow Example (Telemetry Ingestion)

1. `smartmeter-simulator` generates energy generation data and signs it.
2. Payload is sent via gRPC to the `oracle-bridge`.
3. `oracle-bridge` verifies the Ed25519 signature and publishes the validated reading to a Kafka topic (market tier).
4. `trading-service` consumes the reading, calculates the required `surplus_kwh`, and stages a `Pending` settlement in Postgres.
5. A background worker in `trading-service` issues a transaction request to `chain-bridge`.
6. `chain-bridge` verifies the service's identity, requests a signature from Vault, and submits the `execute_generation_mint` instruction to the Solana network.
