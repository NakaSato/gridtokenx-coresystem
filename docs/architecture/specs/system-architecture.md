# GridTokenX — Platform Architecture

This document provides a high-level visual map of the entire GridTokenX ecosystem, including backend services, frontend applications, on-chain programs, and infrastructure components.

## Full System Service Map

```text
 [ FRONTEND LAYER ]          [ EDGE & IOT LAYER ]
 (User Space)                (Device Space)
 +-----------------------+   +-----------------------+
 | Portal (11003)        |   | Smart Meters (DLMS)   |
 | Trading UI (11001)    |   | EV Chargers (OCPP)    |
 | Explorer (11002)      |   | Demand Response (ADR) |
 +-----------+-----------+   +-----------+-----------+
             |                           |
             | HTTPS                     | Public Protocols
             v                           v
 [ GATEWAY LAYER ]           +-----------------------+
 +-----------+-----------+   | Edge Gateway          |
 | APISIX Gateway (4001) |   | (Protocol Translation)|
 +-----------+-----------+   +-----------+-----------+
             |                           |
             |                           | Ed25519 Signed / mTLS
             v                           v
 [ BACKEND SERVICES LAYER ]  +-----------+-----------+
 +-----------+-----------+   | Envoy Proxy (4002)    |
 | IAM Service (4010)    |   | (mTLS Termination)    |
 | Trading Service (4020)|   +-----------+-----------+
 | Noti Service (4060)   |               |
 +-----------+-----------+               v
             |               +-----------+-----------+
             +-------------+ | Oracle Bridge (4030)  |
                           | | (Data Ingestion)      |
                           v +-----------------------+
 [ MESSAGING PLANE ]       [ DATA PLANE ]
 +-----------------------+ +-----------------------+
 | Kafka (9001-9003)     | | PostgreSQL (7001)     |
 | RabbitMQ (9030)       | | Redis (7010)          |
 | NATS JetStream        | | ClickHouse (7030)     |
 +-----------+-----------+ | InfluxDB (7020)       |
             |             | Object Store (S3)     |
             v             +-----------------------+
 [ TRUST & BLOCKCHAIN ]
 +-----------------------+   [ OBSERVABILITY ]
 | Chain Bridge (5040)   |<--+ OTEL Collector      |
 | HashiCorp Vault       |   | Prometheus / Grafana|
 | Solana SVM Programs   |   | Mailpit (13060)     |
 +-----------------------+
```

## Service Inventory & Communication

### 1. Core Services (Rust)
| Service | Role | Communication |
|:---|:---|:---|
| **IAM** | Identity, KYC, Wallet Registry | ConnectRPC, Postgres, Redis, Kafka |
| **Trading** | Order Matching, Settlement | ConnectRPC, Kafka, Postgres, Redis, ClickHouse |
| **Oracle Bridge** | IoT Data Ingestion & Validation | mTLS, InfluxDB, Kafka, Redis |
| **Notification** | Multi-channel Alerts (Email, WS) | ConnectRPC, RabbitMQ, Postgres, Mailpit |
| **Chain Bridge** | Solana Signing & RPC Proxy | NATS, Vault, gRPC |
| **Edge Gateway** | Protocol Translation & Aggregation | DLMS, OCPP, OpenADR → Ed25519 JSON |

### 2. On-Chain Programs (Solana/Anchor)
- **Registry:** On-chain user identity and wallet linkage.
- **Trading:** Non-custodial escrow and atomic settlement.
- **Energy Token:** SPL Token-2022 implementation for renewable credits.
- **Oracle:** Data integrity proofs for energy telemetry.

## Data Flow & Protocols

### 1. Edge Ingestion Flow (Telemetry)
**Path:** `Smart Meter/EVSE` → `Edge Gateway` → `Envoy Proxy` → `Oracle Bridge` → `Kafka` → `Services`

**Stage A: Device to Edge Gateway (Public Protocols)**
- **Smart Meters:** DLMS/COSEM (IEC 62056) over Serial/Optical/Ethernet.
- **EV Chargers:** OCPP 2.0.1 (JSON over WebSocket).
- **Demand Response:** OpenADR 3.0 (HTTP/REST).
- **Distributed Energy (DER):** IEEE 2030.5 (SunSpec CSIP).

**Stage B: Edge Gateway to Cloud (Normalized Core)**
- **Translation:** Edge Gateway normalizes standard protocols into Ed25519-signed JSON.
- **Security:** Submission via mTLS (client-cert) over HTTP/2 to Envoy Proxy.
- **Oracle Bridge:** Validates device signatures and schema before Kafka publishing.
- **Kafka to Trading:** Consumer Groups for NILM validation and VPP forecasting.

### 2. User Operation Flow (REST/WS)
**Path:** `Web/Mobile` → `APISIX Gateway` → `Identity/Trading Services`
- **Client to APISIX:** HTTPS (TLS 1.3) + JWT (RS256) in `Authorization` header.
- **APISIX to Services:** Reverse Proxy with Header Injection (`x-gridtokenx-user-id`).
- **Real-time Updates:** WebSocket (Secure) via Notification Service Hub.

### 3. Internal Service Communication (ConnectRPC)
**Path:** `Service A` → `Service B` (Sync)
- **Protocol:** ConnectRPC (gRPC-compatible) over HTTP/3 (Primary) with HTTP/2 fallback.
- **Format:** Protobuf (Binary) for performance; JSON fallback for debugging.
- **Auth:** Internal Shared Secret (`x-gridtokenx-gateway-secret`) + Role-based headers.

### 4. Blockchain Execution Flow (Write Path)
**Path:** `Service` → `NATS JetStream` → `Chain Bridge` → `Vault` → `Solana RPC`
- **Request:** Service publishes transaction intent to NATS.
- **Signing:** Chain Bridge consumes intent, requests signature from Vault Transit (HMAC-checked).
- **Submission:** Signed transaction broadcasted to Solana RPC cluster via Load Balancer.
- **Confirmation:** Chain Bridge monitors transaction status and updates Redis/Kafka.

## Messaging Strategy

- **Kafka:** Ordered event sourcing (Commands, Market Data, Audit Logs).
- **RabbitMQ:** Reliable task queues (Email delivery, Background retries).
- **NATS JetStream:** High-performance async signing requests for the blockchain.
- **Redis:** Real-time caching, session management, and WebSocket registry.

### 4. Security Model
- **User Space:** JWT (RS256) via APISIX.
- **Service Space:** mTLS (Istio) + Internal Header Secrets.
- **Edge Space:** Ed25519 payload signing + mTLS termination at Envoy.
- **Blockchain Space:** Vault Transit for non-exportable signing keys.
