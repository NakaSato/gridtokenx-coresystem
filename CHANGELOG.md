# Changelog

All notable changes to the GridTokenX Platform will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added
- `ARCHITECTURE.md` — LLM-oriented crate inventory and architecture quick reference
- `CLAUDE.md` — LLM coding conventions and best practices
- `CONTRIBUTING.md` — Developer onboarding and contribution guide
- `docs/glossary.md` — Domain-specific glossary (energy, blockchain, trading, regulatory terms)
- `docs/adr/` — Architecture Decision Records (ADR-0001 through ADR-0004)
- Per-crate `README.md` files for trading-service, chain-bridge, blockchain-core, noti-service
- Updated `gridtokenx-oracle-bridge/README.md` to match current architecture
- `SECURITY.md` — Vulnerability reporting policy
- `CHANGELOG.md` — This file

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
