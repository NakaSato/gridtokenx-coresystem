# Changelog

All notable changes to the GridTokenX Platform will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added
- **Global Platform Hardening**:
  - **Vault Transit Integration**: Migrated all services to HashiCorp Vault Transit for decentralized, secure signing (replaces local AES keys).
  - **SPIFFE/mTLS RBAC**: Implemented identity-aware RBAC across the gRPC mesh using SPIFFE URIs extracted from mTLS certificates.
  - **ConnectRPC Upgrade**: Migrated the Notification Service to the latest ConnectRPC (`0.6.x`) and `buffa` (`0.6.x`) protocol stacks; the remaining Rust services (IAM, Trading, Chain Bridge, Aggregator Bridge) are still on `0.2.x`.
  - **Database Pool**: `iam-service` uses a single SQLx Postgres connection pool (configurable via `DATABASE_MAX_CONNECTIONS`); tiered High/Low-priority routing is not yet implemented.

- **Trading Service & Matching Engine**:
  - **Transactional Outbox**: Implemented the pattern in `trading-service` for 100% reliable event delivery to Kafka/Redis.
  - **Atomic Swap Batching**: Optimized Matching Engine to use batched Solana instructions, significantly reducing compute unit consumption.
  - **Market Locality**: Zone-based Kafka partitioning for consistent routing and future sharding.
  - **Settlement Optimization**: Direct Kafka streaming via UTT (Unified Telemetry Transport) pipeline.

- **Chain Bridge**:
  - **Policy Engine**: Per-instruction program ID allowlist scoped to caller identity (e.g., Trading service can only call Trading/Registry programs).
  - **NATS JetStream Gateway**: High-throughput async transaction submission path with automatic retries and deduplication.
  - **Eight-Layer Defense**: Comprehensive security model (mTLS, SPIFFE, RBAC, Policy, Vault, Idempotency, Staleness, Retries).

- **Aggregator Bridge**:
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

### Changed
- **Docker Compose hardening**:
  - Postgres primary `synchronous_commit` is now env-driven (`PG_SYNCHRONOUS_COMMIT`), defaulting to the durable `on`. Local dev opts into async `off` via `.env`; prod/CI never inherit async commit. Tolerated in dev via Outbox + chain-as-source-of-truth (`docs/RELIABILITY.md`).
  - Monitoring exporter host ports (`postgres`/`redis`/`kafka`/`node`) are now env-overridable (`*_EXPORTER_PORT`) for parallel-stack isolation; defaults unchanged.
  - **PgDog replaces PgBouncer**: PgDog (Rust pooler) is now the sole Postgres connection pooler. Every service's `DATABASE_URL`/`TRADING_DATABASE_URL`/`POSTGIS_URL` and the postgres-exporter DSN point at `pgdog:6432`; the `pgbouncer` container, its `docker/pgbouncer/` config, and `PGBOUNCER_PORT` were removed. Validated against [PgDog docs](https://docs.pgdog.dev): config keys correct; transaction mode auto-pins connections on advisory-lock use and defaults `prepared_statements="extended"` (sqlx's Parse/Bind/Execute). Confirmed live — noti-service first-boot `sqlx` migrate (advisory-lock + DDL) runs clean on a fresh database.
  - **PgDog metrics scraped**: added a Prometheus `pgdog` job for PgDog's native OpenMetrics endpoint (`pgdog:9090/metrics`) — pooler client/server-connection gauges now visible in Grafana. Verified the endpoint serves Prometheus format live.
  - **NTP source configurable**: the five NTP-synced services (iam, trading, aggregator-bridge, chain-bridge, noti) now take `NTP_SERVERS` from compose env (`${NTP_SERVERS:-time.cloudflare.com:123,time.google.com:123}`) instead of only the hard-coded default. Deploys can point at an internal NTP or set `NTP_DISABLE=1`; behaviour degrades safely to the OS clock if unreachable.

### Fixed
- **Compose port mappings**:
  - `postgres-replica-cascade` host port `7003` collided with PgDog (`${PGDOG_PORT:-7003}`); resolved as part of removing the replicas (see below).

### Removed
- **InfluxDB & ClickHouse**: Dropped the unused InfluxDB container (and `INFLUXDB_*` env) and the orphaned `clickhouse_data` volume from `docker-compose.yml` / `docker-compose.db.yml`. No service has a client for either; verified meter telemetry disseminates to zone-partitioned Redis Streams + Kafka. README / `ARCHITECTURE.md` / `docs/glossary.md` realigned to reflect "not provisioned".
- **MinIO**: Removed the unused MinIO (S3 sim) container + `minio_data` volume. No client in any service (no Cargo `s3`/`object_store` dep), no script, and not a Prometheus scrape target — pure orphan.
- **Postgres/Redis read replicas**: Removed `postgres-replica` (`:7002`), `postgres-replica-cascade` (`:7004`), and `redis-replica` (`:7011`) — HA scaffolding with no application consumer (all services read/write the primary). Dropped their volumes, `POSTGRES_REPLICA*_PORT`/`REDIS_REPLICA_PORT` env, the now-inert primary replication GUCs + `setup-replication.sh`/`init-replica.sh` init scripts, and the replica backends in `pgdog.toml` (now primary-only).

---

## [0.1.0] — 2026-04-16

### Platform State at Documentation Baseline

#### Backend Services
- **IAM Service** — Modular monolith (6 sub-crates), user registration, JWT auth, wallet custody, on-chain Registry PDA creation
- **Trading Service** — CDA matching engine, order book, VPP aggregation, REC management, SQLx/Postgres persistence with Redis + Kafka
- **Aggregator Bridge** — Ed25519 telemetry validation, 15-min aggregation, NILM, Redis Streams + Kafka dissemination, Registry sync
- **Chain Bridge** — Vault Transit signing, NATS JetStream transaction submission, gRPC read path
- **Notification Service** — Email delivery, templating, delivery tracking

#### On-Chain Programs (Anchor 1.0.0)
- **Registry** — User PDA, wallet registration
- **Trading** — Order book, market state
- **Energy Token** — SPL Token-2022 mint/burn
- **Oracle** — Telemetry attestation
- **Governance** — Validator set management

#### Infrastructure
- Docker Compose with 30+ containers (PostgreSQL, Redis, Kafka×3, RabbitMQ, InfluxDB, ClickHouse, Vault, APISIX, Grafana stack)
- Structured port numbering scheme (4000–13000 ranges)
- OrbStack Docker runtime for macOS development
- Hybrid messaging architecture (Kafka + RabbitMQ + Redis)

#### Frontend
- Trading UI (Next.js)
- Blockchain Explorer
- Admin Portal
- Smart Meter Simulator (Python/FastAPI)
