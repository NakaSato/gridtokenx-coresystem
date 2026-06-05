# Changelog

All notable changes to the GridTokenX Platform will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added
- **Global Platform Hardening**:
  - **Vault Transit Integration**: Migrated all services to HashiCorp Vault Transit for decentralized, secure signing (replaces local AES keys).
  - **SPIFFE/mTLS RBAC**: Implemented identity-aware RBAC across the gRPC mesh using SPIFFE URIs extracted from mTLS certificates.
  - **ConnectRPC Upgrade**: Migrated all Rust services to the latest ConnectRPC (`0.6.x`) and `buffa` (`0.6.x`) protocol stacks.
  - **Dual Database Pools**: Implemented tiered routing (High vs. Low Priority) in `iam-service` to protect critical paths from long-running queries.

- **Trading Service & Matching Engine**:
  - **Transactional Outbox**: Implemented the pattern in `trading-service` for 100% reliable event delivery to Kafka/Redis.
  - **Atomic Swap Batching**: Optimized Matching Engine to use batched Solana instructions, significantly reducing compute unit consumption.
  - **Market Locality**: Zone-based Kafka partitioning for consistent routing and future sharding.
  - **Settlement Optimization**: Direct Kafka streaming via UTT (Unified Telemetry Transport) pipeline.

- **Chain Bridge**:
  - **Policy Engine**: Per-instruction program ID allowlist scoped to caller identity (e.g., Trading service can only call Trading/Registry programs).
  - **NATS JetStream Gateway**: High-throughput async transaction submission path with automatic retries and deduplication.
  - **Eight-Layer Defense**: Comprehensive security model (mTLS, SPIFFE, RBAC, Policy, Vault, Idempotency, Staleness, Retries).

- **Oracle Bridge**:
  - **Secure Protocol V4**: Implemented Secure DLMS-lite v4 binary protocol with AES-256-GCM encryption and CRC-32 integrity.
  - **Grid Dispatch Engine**: Real-time frequency monitoring from Kafka with automated VPP response triggers.
  - **Unified Telemetry Transport**: Optimized ingest path that bypasses legacy HTTP/gRPC in favor of direct Redis-to-Kafka streaming.

- **IAM Service**:
  - **OWS Wallet Support**: Integration with Omni-Wallet Standard (OWS) for interoperable user wallet management.
  - **Meter Management API**: Comprehensive CRUD for meters with automated on-chain registration and verification.
  - **On-Chain Auto-Registration**: Automated Registry PDA creation for secondary wallets.

- **Notification Service**:
  - **WebSocket Support**: Real-time push notifications for trading and grid events.
  - **Dual-Bus Consumers**: Simultaneous processing of Kafka (Grid Status) and RabbitMQ (Business Events).
  - **Tera Templating**: Added production-ready templates for VPP dispatch, security alerts, and token issuance.

- **On-Chain Programs (Anchor)**:
  - **Zone Configuration**: Added on-chain `ZoneConfig` to the Trading program for locational market parameters.
  - **ERC Logic**: Enhanced Energy Reconciliation Certificate handlers in the Governance program.
  - **DAO Transition**: Initial implementation of DAO voting logic in governance tests.

- `ARCHITECTURE.md` — LLM-oriented crate inventory and architecture quick reference
- `CLAUDE.md` — LLM coding conventions and best practices
- `CONTRIBUTING.md` — Developer onboarding and contribution guide
- `docs/glossary.md` — Domain-specific glossary (energy, blockchain, trading, regulatory terms)
- `docs/adr/0005-direct-edge-signing-and-telemetry-ingestion.md` — New ADR for UTT architecture

---

## [0.1.0] — 2026-04-16

### Platform State at Documentation Baseline

#### Backend Services
- **IAM Service** — Modular monolith (6 sub-crates), user registration, JWT auth, wallet custody, on-chain Registry PDA creation
- **Trading Service** — CDA matching engine, order book, VPP aggregation, REC management, ClickHouse CQRS
- **Oracle Bridge** — Ed25519 telemetry validation, 15-min aggregation, NILM, InfluxDB time-series, Registry sync
- **Chain Bridge** — Vault Transit signing, NATS JetStream transaction submission, gRPC read path
- **Notification Service** — Email delivery, templating, delivery tracking

#### On-Chain Programs (Anchor 1.0.0)
- **Registry** — User PDA, wallet registration
- **Trading** — Order book, market state
- **Energy Token** — SPL Token-2022 mint/burn
- **Oracle** — Telemetry attestation
- **Governance** — Validator set management

#### Infrastructure
- Docker Compose with 30+ containers (PostgreSQL, Redis, Kafka×3, RabbitMQ, InfluxDB, ClickHouse, Vault, APISIX, Envoy, Grafana stack)
- Structured port numbering scheme (4000–13000 ranges)
- OrbStack Docker runtime for macOS development
- Hybrid messaging architecture (Kafka + RabbitMQ + Redis)

#### Frontend
- Trading UI (Next.js)
- Blockchain Explorer
- Admin Portal
- Smart Meter Simulator (Python/FastAPI)
