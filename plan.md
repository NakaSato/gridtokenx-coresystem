# GridTokenX Scaling & Reliability Roadmap

This document tracks the strategic goals for scaling the GridTokenX platform to handle 800M+ users and ensuring mission-critical reliability.

## Phase 1: High-Performance Foundation [COMPLETED]
- [x] **Solana Program Optimization**: Refactor Registry and Trading programs for compute efficiency.
- [x] **gRPC Mesh**: Implement ConnectRPC across all core services for low-latency communication.
- [x] **Unified EventBus**: Implement hybrid Kafka/Redis messaging for market data and telemetry.
- [x] **CQRS with ClickHouse**: Offload analytical queries from PostgreSQL to ClickHouse.

## Phase 2: Sharding & Atomic Batching [COMPLETED]
- [x] **Matching Engine Scale**: Implement Atomic swap batching to minimize on-chain instruction count.
- [x] **Market Locality**: Refactor Kafka partitioning to use `zone_id` for consistent routing and sharding.
- [x] **Transactional Outbox**: Implement the Outbox pattern in `trading-service` to guarantee event delivery under load.

## Phase 3: Load Testing & Hardening [IN PROGRESS]
- [x] **Secure Telemetry (UTT)**: Implemented Secure DLMS-lite v4 and Unified Telemetry Transport for high-scale ingest.
- [x] **Core Reliability**: Transactional Outbox and Dual-Bus (Kafka/RabbitMQ) messaging finalized.
- [x] **Identity & Signing**: Vault Transit and SPIFFE/mTLS RBAC deployed across the mesh.
- [ ] **Simulation Scale-up**: Scale `smartmeter-simulator` to generate 100k+ concurrent streams.
- [ ] **Load Test - Phase 1**: Execute 10k TPS matching benchmarks on localnet/devnet.
- [ ] **Disaster Recovery**: Verify system behavior during Kafka/PostgreSQL failover.
- [ ] **Observability Hardening**: Fine-tune SigNoz/Tempo for high-cardinality trace data.

## Phase 4: Decentralized Governance & Expansion [TODO]
- [ ] **Validator DAO**: Implement on-chain voting for grid parameters (zone fees, multipliers).
- [ ] **Cross-Zone Settlement**: Support P2P trades across different grid zones with loss-factor calculation.
- [ ] **Regulatory Reporting**: Automated compliance export for national energy regulators.

---
*Last Updated: 2026-06-03*
