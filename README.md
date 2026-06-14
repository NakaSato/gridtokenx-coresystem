# GridTokenX Platform

[![GridTokenX](https://img.shields.io/badge/Platform-Production--Ready-brightgreen)](https://gridtokenx.com)
[![Solana](https://img.shields.io/badge/Blockchain-Solana-blueviolet)](https://solana.com)
[![License](https://img.shields.io/badge/License-Proprietary-red)](LICENSE)

**GridTokenX** is a next-generation, blockchain-powered Peer-to-Peer (P2P) energy trading platform. It enables prosumers (energy producers) and consumers to trade energy directly, ensuring trustless on-chain settlement, high-performance telemetry ingestion, and decentralized grid stabilization.

The platform bridges **physical energy infrastructure** (smart meters, solar inverters, EV chargers) with **trustless financial markets** on the Solana blockchain, leveraging a high-performance Rust-based microservices mesh for scalability, data integrity, and low-latency matching.

---

## Architecture at a Glance

GridTokenX follows a **Modern Microservices Architecture** orchestrated by a high-performance Rust gateway and secured by Solana smart contracts. The system consists of **5 core Rust services**, **3 frontend applications**, **30+ Docker containers** for infrastructure, and **5 Anchor programs** on Solana.

> **Repo layout**: this is a **git superproject** — every `gridtokenx-*` service is a git submodule (see `.gitmodules`). There is **no root `Cargo.toml`**; each service is an independent Cargo workspace. Always clone with `--recursive`, and after switching branches run `git submodule update --init --recursive`.

### Platform Architecture

```mermaid
graph TD
    subgraph "Public Entry"
        Client[Trading UI / Portal] -->|HTTPS/WSS| APISIX[Apache APISIX :4001]
        EdgeMeter[Smart Meter] -->|Ed25519-signed HTTP| OracleB
    end

    subgraph "GridTokenX Service Mesh"
        APISIX -->|ConnectRPC| APIS[API Services Orchestrator :4000]
        APIS <-->|gRPC| IAM[IAM Service :4010/5010]
        APIS <-->|gRPC| Trading[Trading Service :4020/5020]
        APIS <-->|gRPC| OracleB[Aggregator Bridge :4030/5030]
    end

    subgraph "Blockchain Interface"
        IAM & Trading & OracleB -->|gRPC| ChainBridge[Chain Bridge :5040]
    end

    subgraph "Blockchain Layer"
        ChainBridge -->|RPC| Solana[Solana Blockchain]
    end

    subgraph "Messaging & Persistence"
        IAM & Trading & OracleB -->|Kafka| Events[Kafka: cmd/market/audit]
        IAM & Trading & OracleB -->|RabbitMQ| Tasks[RabbitMQ :5672]
        IAM & Trading & OracleB -->|Redis| Live[Redis Pub/Sub]
        IAM & Trading -->|SQLx| PostgreS[(PostgreSQL 17)]
        OracleB -->|Streams| ZoneRedis[Redis Streams: zone-partitioned]
    end
```

### Two Interconnected Platforms

GridTokenX is architected as **two distinct but interconnected platforms**:

| Aspect | **Exchange Platform** | **Infrastructure Platform** |
| :--- | :--- | :--- |
| **Primary Domain** | Financial / Trading | Physical / Data Integrity |
| **Blockchain Access** | ✅ Direct (IAM, Trading) | ❌ Indirect (signs only) |
| **Data Direction** | Receives validated data | Produces validated data |
| **Scaling Factor** | Trading volume / User count | Device count / Telemetry volume |
| **Key Services** | API Services, IAM, Trading | Edge Gateway, Aggregator Bridge |

### Edge-to-Blockchain Data Flow

```
Edge Meter → Edge Gateway → Aggregator Bridge ───┐
                                              IAM Service ─┐
User/Web → APISIX (User Gateway) ───────────────┼→ Trading Service─┼→ Solana Blockchain
                                              Oracle Service─┘
                                              Chain Bridge ──┘
```

---

## Technology Stack

### Backend Core

-   **Language**: Rust (2021 Edition)
-   **Web Framework**: Axum (REST), Tonic/ConnectRPC (gRPC over HTTP/2)
-   **Async Runtime**: Tokio (multi-threaded)
-   **Database ORM**: SQLx with compile-time query verification
-   **Error Handling**: `anyhow::Result` for application logic

### Blockchain

-   **Platform**: Solana (localnet for dev, devnet/testnet for staging)
-   **Smart Contracts**: Anchor Framework (1.0.0)
-   **Token Standard**: SPL Token-2022
-   **Programs**: Registry, Trading, Energy Token, Oracle, Governance

### Messaging (Hybrid Architecture)

| Technology | Role | Primary Use Case | Performance |
| :--- | :--- | :--- | :--- |
| **Kafka** (3 clusters) | Event Sourcing Log | Orders, trades, audit trails — strict ordering, 168h retention | High Throughput |
| **RabbitMQ** | Task Queues | Email notifications, settlement retries, DLQ, guaranteed delivery | High Reliability |
| **Redis 7** | Real-Time Engine | WebSocket fan-out, session cache, sub-millisecond access | Ultra-Low Latency |

### Persistence

| Component | Version | Purpose |
|-----------|---------|---------|
| **PostgreSQL 17** | Primary + Replica | User data, orders, trades, **Transactional Outbox** |
| **Redis 7** | Primary + Replica | Cache, session, Pub/Sub, zone-partitioned meter Streams |

### Infrastructure & Observability

-   **Docker Runtime**: **OrbStack** (2s startup, faster networking, battery optimized)
-   **API Gateway**: Apache APISIX (User-facing, port 4001)
-   **Secrets Management**: HashiCorp Vault (port 8200)
-   **Observability**: Prometheus, Grafana (port 3001), Loki, Tempo, OpenTelemetry, SigNoz

### Frontend

-   **Trading UI**: Next.js (React, port 11001)
-   **Explorer**: Platform-specific blockchain explorer
-   **Portal**: Administrative dashboard

---

## Core Services

### 1. API Services (`gridtokenx-api`) — Lead Orchestrator
-   **Port**: 4000 (HTTP)
-   **Role**: Central nervous system. Aggregates responses from microservices, manages real-time WebSocket broadcasting via Redis Pub/Sub, executes background persistence workers for telemetry ingestion (20k+ readings/sec).
-   **Tech**: Rust (Axum), ConnectRPC

### 2. IAM Service (`gridtokenx-iam-service`) — Identity Guardian
-   **Ports**: 4010 (REST) / 5010 (gRPC via ConnectRPC)
-   **Role**: User registration, KYC workflows, secure wallet custody. Generates/encrypts Ed25519 keypairs. Manages Registry Program on-chain. Issues scoped JWTs.
-   **Security**: AES-256-GCM encryption, argon2id password hashing, JWT auth
-   **Blockchain**: Registry + Governance programs

### 3. Trading Service (`gridtokenx-trading-service`) — Matching Engine
-   **Ports**: 8092 (gRPC-primary) / 8093 (REST metrics + settlement)
-   **Role**: In-memory order book management, Continuous Double Auction (CDA) matching, on-chain settlement. Handles conditional orders (stop-loss, take-profit), recurring DCA orders, VPP aggregation, ERC certificate management.
-   **Complexity**: 587-line startup file, 1883-line gRPC implementation (40+ RPCs)
-   **Blockchain**: Trading + Energy Token programs

### 4. Aggregator Bridge (`gridtokenx-aggregator-bridge`) — Cryptographic Trust Layer
-   **Port**: 4030 (Unified gRPC/HTTP)
-   **Role**: Validates Ed25519 signatures from Edge Gateways, performs zone-based partitioning, aggregates 15-minute settlement windows. Bridges physical energy data to digital markets.
-   **Blockchain**: Oracle Program

### 5. Chain Bridge (`gridtokenx-chain-bridge`) — Decentralized Signing Authority
-   **Port**: 5040 (gRPC via ConnectRPC)
-   **Role**: Decentralized signing authority and Solana blockchain interface. All services route blockchain transactions through Chain Bridge for distributed key management.

### 6. Edge Gateway (`gridtokenx-edge-gateway`) — Edge Aggregation
-   **Role**: Local aggregation, buffering, protocol translation, Ed25519 signing. Hardware-specific (RPi, rppal, MQTT).
-   **Communication**: Sends validated telemetry directly to the Aggregator Bridge IoT gateway (Ed25519-signed payloads)

---

## Quick Start

### Prerequisites
-   **OrbStack**: Optimized Docker runtime for macOS (not Docker Desktop)
-   **Rust Toolchain**: `rustup`, `cargo`
-   **Solana CLI & Anchor**: For blockchain interaction
-   **Nushell**: For `grx` helper script
-   **just**: Task runner

### 1. Initialize the Platform
```bash
# Clone and setup
git clone --recursive https://github.com/gridtokenx/platform.git
cd platform

# Copy environment configuration
cp .env.example .env

# Generate dev mTLS certs for Chain Bridge (CA + server + per-service SPIFFE client certs)
just gen-certs

# Start the unified infrastructure (PostgreSQL, Redis, Kafka, APISIX, NATS, Vault)
./scripts/app.sh start --docker-only

# Initialize the blockchain state and deploy Anchor programs
./scripts/app.sh init
```

### 2. Database Setup
```bash
# Run PostgreSQL migrations
just migrate
```

### 3. Launch Services
```bash
# Recommended: Native Apps Mode (best dev experience)
./scripts/app.sh start --native-apps

# Monitor background services
tail -f logs/*.log
```

### 4. Performance Tuning (Optional)
For production-grade high-throughput setups, configure Firedancer, Hugepages, and CPU pinning. On macOS Apple Silicon, `solana-test-validator` requires raised file limits — `app.sh` sets `ulimit -n 65536` automatically.

---

## Development Commands

### Platform Management (`scripts/app.sh`)
```bash
./scripts/app.sh start              # Start all infrastructure + services
./scripts/app.sh start --docker-only  # Start only Docker infrastructure
./scripts/app.sh start --native-apps  # Docker + native app services (background)
./scripts/app.sh stop               # Gracefully stop the platform
./scripts/app.sh init               # Initialize Solana + deploy programs
./scripts/app.sh register           # Register admin user
./scripts/app.sh seed               # Seed database with test users
./scripts/app.sh status             # Check running services
./scripts/app.sh doctor             # Check dependencies + health
```

### Task Automation (`just`)
```bash
just check-all          # cargo check all microservices
just build-all          # Build all microservice binaries
just test               # Run all microservice tests
just test-all           # Run all tests + integration tests (Solana validator)
just test-edge          # Run Edge Protocol integration test
just test-registration  # Run User Registration & Onboarding E2E test
just migrate            # Run sqlx migrations (IAM Service)
just migrate-new name:X # Create new IAM migration
just migrate-revert     # Revert last IAM migration
just migrate-info       # Show migration status
just db-up              # Start PostgreSQL container
just db-down            # Stop PostgreSQL container
just orb-up             # Start all OrbStack services
just orb-down           # Stop all OrbStack services
just fmt                # Format all code (cargo fmt)
just clippy             # Run clippy on all services (-- -D warnings)
just clean-all          # Clean all build artifacts
just benchmark          # Run trading engine benchmarks
just simnet             # Start Solana Mainnet Simulation (Surfpool)
just simnet-ci          # Start Solana Simnet in CI mode
just simnet-down        # Stop Solana Simnet
just orb-rebuild        # Rebuild all Docker services (no cache)
```

### Nushell Helper (`grx.nu`)
```bash
grx check     # cargo check
grx build     # cargo build
grx test      # cargo test
grx migrate   # sqlx migrate run
grx db-up     # Start PostgreSQL
grx db-down   # Stop PostgreSQL
grx orb-up    # Start all Docker services
grx orb-down  # Stop all Docker services
grx prepare   # sqlx prepare (offline query preparation)
```

---

## Service Registry

| Component | HTTP Port | gRPC Port | Role |
| :--- | :--- | :--- | :--- |
| **APISIX Gateway** | `4001` | — | Unified Gateway Routing |
| **Direct Gateway** | `4000` | — | Platform HTTP API & Health |
| **IAM Service** | `4010` | `5010` | Identity, Auth & KYC |
| **Trading Service** | `8093` | `8092` | Matching & Settlement |
| **Aggregator Bridge** | — | `4030` | Telemetry Validation |
| **Chain Bridge** | — | `5040` | Solana Signing Authority |
| **Noti Service** | — | `5050` | Notifications Dispatcher |
| **Simulator API** | `12010` | — | IoT Simulation Backend |
| **Trading UI** | `11001` | — | Exchange Web App |
| **Explorer UI** | `11002` | — | Block Explorer UI |
| **Simulator UI** | `12011` | — | Smart Meter Simulator Map |
| **PostgreSQL** | `7001` | — | Relational store (primary) |
| **[PgDog](https://docs.pgdog.dev)** | `7003` | — | Sole Postgres pooler (in-network `pgdog:6432`; all services route here) |
| **Redis** | `7010` | — | Cache, Session, Pub/Sub, meter Streams |
| **RabbitMQ** | `9030` (AMQP) / `9031` (mgmt) | — | Task Queues |
| **Kafka** | `29001` | — | Event Bus / Broker |
| **Grafana** | `6002` | — | Metrics Dashboard |
| **Prometheus** | `6001` | — | Metrics Scraper |
| **Loki** | `6003` | — | Log Aggregator |

---

## On-Chain Program IDs (Localnet)

| Program | ID |
| :--- | :--- |
| **Registry** | `5xdQsDuGa1AaLVnddGhevvf2bngCvSob4dAepETS7oaJ` |
| **Trading** | `DA9TdkcToi5r7oS7X5CddoMBiGNF3sAGqwPQph1CfLwd` |
| **Energy Token** | `EzXnJoHSjS6VR7eBwHTkHHAJGqVfRsEvyksqz7uJCBpe` |
| **Oracle** | `D5MCbSHxhxZTRFyUMdTHcQvjzwjx5Lb8jg9PQ2LTja8S` |
| **Governance** | `BRQEyx7DHX1Ljx1eNTHUve52aHHwkWckBXGeL9FZPEgZ` |

---

## Workspace Structure

Each `gridtokenx-*` entry below is a **git submodule** with its own Cargo workspace — there is no root `Cargo.toml`.

```
gridtokenx-coresystem/                # superproject (git submodules)
├── gridtokenx-iam-service/          # Identity, Auth, KYC, Registry (Rust)
├── gridtokenx-trading-service/      # Order Matching, Settlement (Rust)
├── gridtokenx-aggregator-bridge/    # Edge Validation, IoT Ingestion (Rust)
├── gridtokenx-chain-bridge/         # Decentralized Signing Authority (Rust)
├── gridtokenx-noti-service/         # Notifications Dispatcher (Rust)
├── gridtokenx-anchor/               # Solana Anchor Programs
│   ├── programs/                    # Registry, Trading, Energy Token, Oracle, Governance
│   ├── tests/                       # Program integration tests
│   └── shared/                      # Shared types between programs
├── gridtokenx-blockchain-core/      # Shared blockchain utilities
├── gridtokenx-wasm/                 # WebAssembly utilities
├── gridtokenx-smartmeter-simulator/ # IoT Device Simulator (Python/FastAPI)
├── gridtokenx-trading/              # Trading UI (Next.js)
├── gridtokenx-explorer/             # Blockchain Explorer
├── apisix_conf/                     # APISIX Gateway Configuration
├── docker-compose.yml               # Main Docker Compose
├── docker-compose.db.yml            # Database-specific Compose
├── Justfile                         # Task Runner (Nushell)
├── grx.nu                           # Nushell Helper
├── academic/                        # Whitepaper / thesis (Typst)
├── docs/                            # Platform Documentation
├── scripts/
│   └── app.sh                       # Unified Platform Manager
└── tests/
    └── load-test/                   # Load Testing Tool
```

> The API orchestrator (`gridtokenx-api`, `:4000`), Edge Gateway (`gridtokenx-edge-gateway`), and Admin Portal (`gridtokenx-portal`) are referenced throughout the architecture but are **not submodules of this superproject** — they live in separate repos.

### Per-Service Cargo Workspaces

Each Rust service builds independently. Trading Service and Edge Gateway are kept out of any shared workspace due to target conflicts.

| Service | Description | Notes |
|-------|-------------|-----------|
| `gridtokenx-iam-service` | Identity & Access Management | Modular monolith, 6 sub-crates |
| `gridtokenx-trading-service` | Trading Engine & Matching | Separate workspace (BPF target) |
| `gridtokenx-aggregator-bridge` | Edge Validation & IoT | — |
| `gridtokenx-chain-bridge` | Decentralized Signing | Binds `0.0.0.0`; isolated by mTLS + RBAC |
| `gridtokenx-noti-service` | Notifications Dispatcher | — |
| `gridtokenx-blockchain-core` | Shared Blockchain Utilities | — |
| `gridtokenx-wasm` | WebAssembly | — |
| `gridtokenx-anchor/programs/*` | Anchor Programs | BPF |
| `gridtokenx-smartmeter-simulator` | IoT Simulation | Python/FastAPI |

---

## Security Model

-   **Wallet Custody**: Private keys encrypted with AES-256-GCM using master secret from environment. Never stored in plaintext.
-   **Authentication**: JWT tokens (scoped), API keys, bcrypt/argon2 password hashing
-   **Edge Validation**: Ed25519 signature verification at edge and oracle layers
-   **Distributed Signing**: Blockchain signing keys distributed per-service (not centralized)
-   **Edge Device Auth**: Aggregator Bridge verifies Ed25519-signed payloads from IoT devices (per-device key identity)
-   **Secrets Management**: HashiCorp Vault for key management and secret rotation
-   **Database Security**: SQLx with compile-time query checking, parameterized queries

---

## Key Documentation

Detailed specifications are located in the `/docs` directory:

-   [National Control Plane Design](docs/product-specs/National.md)
-   [gTHB Issuer Service Spec](docs/product-specs/gTHB_ISSUER_SERVICE.md)
-   [System Architecture](ARCHITECTURE.md)
-   [Documentation Map](docs/DESIGN.md)
-   [Glossary](docs/glossary.md)

---

## License

Proprietary Software. © 2026 GridTokenX. All Rights Reserved.
