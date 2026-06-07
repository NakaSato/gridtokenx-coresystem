# GridTokenX System Architecture

This document describes the deployment topology and runtime architecture of the GridTokenX platform as implemented in the current codebase. It is the canonical reference for service boundaries, identity, messaging, and the on-chain/off-chain seam. Detailed contract specifications, ML model behaviour, and DevOps procedures are out of scope and live in their own documents.

## 1. Architectural Model

GridTokenX is structured as a four-layer system. Each layer has a single responsibility and a tightly defined contract with the layers above and below it. All cross-layer communication is authenticated; nothing trusts headers alone.

| Layer | Function | Trust Anchor |
|---|---|---|
| **L4 — Application** | Web UI, mobile, operator console, partner APIs | Public TLS, JWT |
| **L3 — Blockchain / Settlement** | Solana programs (Anchor), Chain Bridge, Vault | SPIFFE + Vault Transit |
| **L2 — Core Services** | IAM, Trading, Oracle Bridge, Notification | SPIFFE mTLS |
| **L1 — Physical / Edge** | Smart meters, simulators, IoT devices | Device Ed25519 keys |

The hard rule between L3 and everything below it: **no service holds a private key**. Signing is delegated to Vault Transit; identity is asserted via SPIFFE and verified at the Chain Bridge.

## 2. Topology

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ L4 — EXTERNAL CLIENTS                                                   │
│   Web (trading-ui)   Operator Console   Mobile   Partner Integrations   │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │ HTTPS / mTLS
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ EDGE & API GATEWAYS                                                     │
│   APISIX  ── user/web traffic, JWT, rate limit                          │
│   Envoy   ── IoT/device ingress, mTLS termination, SPIFFE attestation   │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │ SPIFFE mTLS (internal mesh)
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ L2 — CORE MICROSERVICES (Rust)                                          │
│   iam-service           identity, JWT, wallet authority mapping         │
│   trading-service       CDA matcher, escrow, zone markets, settlement   │
│   oracle-bridge         zone-partitioned telemetry, signature verify    │
│   noti-service          email/WS/webhook dispatch (Kafka + RabbitMQ)    │
└─────┬─────────────────────────────────────────┬─────────────────────────┘
      │                                         │
      ▼  (segmented event bus)                  ▼  (single-writer to chain)
┌──────────────────────────┐         ┌──────────────────────────────────┐
│ MESSAGING TIERS          │         │ L3 — BLOCKCHAIN INTERFACE        │
│   Kafka (Command)        │         │   chain-bridge                   │
│   Kafka (Market)         │         │     • PolicyEngine (allowlist)   │
│   Kafka (Audit)          │         │     • SPIFFE RBAC                │
│   NATS JetStream (Tx)    │         │     • Vault Transit (Ed25519)    │
│   RabbitMQ (Dispatch)    │         │     • RPC client → Solana        │
│   Redis Streams (IoT)    │         │   Vault (Transit Secrets Engine) │
└──────────────────────────┘         └────────────────┬─────────────────┘
                                                      │ JSON-RPC
                                                      ▼
                          ┌─────────────────────────────────────────┐
                          │ SOLANA (localnet / devnet / PoA L1)     │
                          │   energy-token   trading   registry     │
                          │   oracle         governance  erc        │
                          └─────────────────────────────────────────┘
```

## 3. Identity and Trust Model

Identity is the spine of the system. Every internal call carries a SPIFFE URI; every privileged operation is authorized against it.

### 3.1 SPIFFE namespace

All workloads are issued SVIDs under the trust domain `spiffe://gridtokenx.th/prod/`. The platform recognizes the following identities:

| SPIFFE URI prefix | Role |
|---|---|
| `…/apisix` | `ApiGateway` — public ingress |
| `…/iam-service` | `IamService` — identity authority |
| `…/trading-service/api` | `TradingApi` — order intake |
| `…/trading-service/matcher` | `TradingMatcher` — CDA engine |
| `…/oracle-bridge` | `OracleBridge` — telemetry ingress |
| `…/settlement-service` | `SettlementService` — on-chain settlement worker |
| `…/reporting-service` | `ReportingService` — analytics |
| `…/admin` | `Admin` — break-glass operator |

Resolution happens at the request edge: SPIFFE identity is extracted from the mTLS peer certificate and inserted into request extensions before any handler sees it. The `INTERNAL_ROLE_HEADER` (`x-gridtokenx-role`) exists only as a development fallback for environments without SPIRE; it is rejected in production deployments.

### 3.2 The Chain Bridge PolicyEngine

The Chain Bridge enforces a second authorization gate at the instruction level. Before any transaction is signed, every instruction's program ID is checked against an allowlist keyed by the caller's SPIFFE identity:

- `trading-service/*` may invoke: `trading`, `registry`, `energy-token`
- `oracle-bridge` may invoke: `oracle` only
- `iam-service` may invoke: `registry` (user onboarding)
- All identities may invoke: `system_program` (account creation)

This means a compromised Oracle Bridge cannot issue a token mint, and a compromised Trading Service cannot publish a forged meter reading. The policy is enforced before Vault is asked to sign — Vault never sees a transaction that would not be authorized to begin with.

### 3.3 Keys never leave Vault

The Chain Bridge is the **only** component that talks to Vault Transit, and it does so via the prehashed Ed25519 path. No microservice — including the Chain Bridge itself — ever holds raw key material in memory. There is a single signing identity (`platform_admin`) used as the fee payer and on-chain authority across all programs; per-user authority is represented by Vault-custodied pubkeys with no corresponding signers.

> **Known rough edge:** the prehashed Ed25519 regression in `hashicorp/vault#31574` remains open. The Chain Bridge currently pins to a known-good Vault version; the workaround must not be silently removed.

## 4. Core Services (L2)

All L2 services are Rust binaries built from a single workspace. They share a common transport convention: **internal traffic is gRPC (tonic + connectrpc) over TCP**; HTTP/JSON is exposed only at the user-facing edge. QUIC/H3 is reserved for the public mobile-subscriber WebSocket and SSE paths in `noti-server` and is not used internally.

### 4.1 `iam-service`

Identity authority for the platform. Owns user accounts, API keys, JWT issuance, KYC state, and the off-chain mapping between human users and their Vault-custodied wallet authority pubkeys. Exposes REST (public, via APISIX) and gRPC (internal). Emits domain events (`UserRegistered`, `UserOnboarded`, `MeterOnboarded`) onto the Command tier of Kafka with `acks=all` for durability.

### 4.2 `trading-service`

The matching and settlement core. Splits internally into two SPIFFE identities:

- **TradingApi** — accepts orders, enforces price bounds, persists to Postgres.
- **TradingMatcher** — runs the Continuous Double Auction engine.

On-chain state is sharded by **zone**: each microgrid zone gets its own `ZoneMarket` PDA carrying its own order-book depth (`MAX_DEPTH_LEVELS = 10` per side). This isolates write contention so Koh Tao traders don't serialize behind Khanom traders. Per-user `escrow` PDAs are derived from `[b"escrow", user.key(), mint.key()]`, binding settlement to the seed derivation rather than to a caller-supplied address.

The settlement path supports both batch-cleared (`execute_batch`) and CDA-style (`submit_limit_order` → `match_orders`) flows. Fee, wheeling, and loss collectors are PDA token accounts under `market_authority`, so the off-chain settlement worker cannot redirect protocol revenue.

### 4.3 `oracle-bridge`

Telemetry ingress for smart meters and the GLM-based simulator. Runs in zone-partitioned mode (`IOT_NUM_ZONES`, default 10), with a dedicated `ZoneEventIngester` per zone so meter floods in one zone don't head-of-line block others. The pipeline is:

1. Device payload arrives via gRPC (mTLS) or HTTP (legacy/dev).
2. Ed25519 signature is verified against the device's registered key.
3. Validated reading is fanned out to:
   - **Redis Streams** — low-latency dissemination to in-process consumers.
   - **Kafka (Market tier)** — durable stream for the matcher and analytics.
   - **NATS** — telemetry forwarding to subscribers.
4. The Dispatch Engine subscribes to a separate `gridtokenx.oracle.grid_status` topic and feeds the demand-response control loop.

Supported edge stacks: DLMS/COSEM, OCPP, OpenADR, SunSpec.

### 4.4 `noti-service`

Async fanout for user-visible events. Six-layer internal design (`noti-server` → `NotificationOrchestrator` → `noti-core` / `noti-persistence`) with provider implementations for SMTP, WebSocket (`ConnectionManager`), webhook, push, and SMS. Consumes from Kafka (IAM and trading events) and RabbitMQ (background dispatch with DLX). Templates are rendered with Tera; cache via Redis.

## 5. Messaging Architecture

Traffic is segmented by **delivery semantics**, not by service. Mixing a 50 ms market-data stream with a 30-day audit trail on the same broker is an availability hazard, so the buses are split:

| Bus | Tier | Durability | Retention | Typical traffic |
|---|---|---|---|---|
| Kafka | **Command** | `acks=all`, replicated | 7 d | User events, KYC, settlement commands |
| Kafka | **Market** | `acks=all`, replicated | 24 h | Meter readings, order events, grid status |
| Kafka | **Audit** | `acks=all`, replicated | ≥1 y | Regulatory log, policy decisions, admin actions |
| NATS JetStream | **Transaction** | At-least-once, WAL-backed | hours | Chain Bridge transaction requests |
| RabbitMQ | **Dispatch** | DLX-backed | per-queue | Notification fanout, RPC-style work |
| Redis Streams | **Transient** | Best-effort | minutes | Zone-local IoT dissemination |

The Chain Bridge specifically uses **NATS JetStream as a durable write-ahead log** for transaction requests, with gRPC as the synchronous fallback. This lets services fire-and-forget transactions during chain unavailability without losing the request.

## 6. Persistence Tier

- **PostgreSQL** — primary transactional store. Topology is primary + read replica + cascading read replica behind PgBouncer. Hot tables (`trading_orders`, `order_matches`) carry composite indexes tuned for the order-book and zone-analytics access patterns; `order_matches.match_time` uses a BRIN index for time-series scans.
- **Redis** — caching for IAM (session, token introspection) and Trading (order book hot path), plus the Streams transport above.
- **ClickHouse** — OLAP for trade history, settlement analytics, regulatory reporting.
- **InfluxDB** — raw smart-meter telemetry, retained at full fidelity for forecasting model retraining.
- **MinIO** — S3-compatible object store for cold settlements, large payloads, model artefacts.

## 7. Blockchain Layer (L3)

### 7.1 On-chain programs

The Anchor program set, with their fixed PDAs and responsibilities:

| Program | Purpose | Key PDAs |
|---|---|---|
| `energy-token` | SPL Token-2022 mint of the GRID token; 1 kWh = 1 GRID | `mint_2022`, `token_info_2022` |
| `trading` | CDA order book, batch clearing, escrow, fee/wheeling/loss collectors | `market`, `zone_market`, `escrow`, `market_authority` |
| `registry` | User and meter registration, shard assignment | `user_account`, `meter`, `registry_shard` |
| `oracle` | Validated meter readings, grid-state snapshots | `oracle_data` |
| `governance` | Operational-mode flags, parameter changes | `governance_config` |
| `erc` | Renewable Energy Certificate issuance and transfer | per-certificate PDAs |

The shard assignment is enforced on-chain: `registry::shard_for(authority) == authority.to_bytes()[0] % 16`. The Chain Bridge derives it as the single source of truth; a stale caller value yields `0x177c InvalidShardId`.

### 7.2 `chain-bridge`

The exclusive gateway to Solana. Its invariants:

1. **mTLS in, mTLS out.** Caller identity is the peer SPIFFE cert; no header-based identity in production.
2. **PolicyEngine before signing.** Every instruction in every transaction is checked against the caller's program allowlist.
3. **Vault Transit is the only signer.** No keypair files, no in-memory secrets.
4. **Single signing path.** `platform_admin` is the only Vault key; all on-chain authority flows through it.
5. **Dual ingestion.** Synchronous gRPC for request/response; NATS JetStream for durable async submission.
6. **Simnet-first testing.** LiteSVM for unit and integration tests; `solana-test-validator` only for end-to-end smoke.

Three known production gaps remain ring-fenced:

- Instruction-level transaction policy engine — the per-program allowlist exists, but a per-instruction parameter policy (e.g. "Oracle Bridge may publish readings ≤ 1 MWh/event") is not yet enforced.
- Tamper-evident audit log — current logs are append-only at the storage layer but not cryptographically chained.
- Pre-sign transaction simulation — every transaction should be simulated against current state before signing, to catch state drift; this exists as a code path but is not yet on by default.

## 8. Data Flow Examples

### 8.1 Telemetry → Token Mint

1. `smartmeter-simulator` (or a physical AMI device) generates an energy-generation reading and signs the payload with its device Ed25519 key.
2. Payload arrives at `oracle-bridge` over mTLS gRPC, routed to the appropriate `ZoneEventIngester` by zone ID.
3. `oracle-bridge` verifies the device signature against the registered meter pubkey, attaches a confidence score, and publishes to:
   - Redis Streams (low-latency consumers)
   - Kafka Market tier (durable fanout)
4. `trading-service` (or a settlement worker) consumes the reading, aggregates `surplus_kwh` per user, and stages a `Pending` row in Postgres.
5. The worker emits a transaction request to `chain-bridge` via NATS JetStream.
6. `chain-bridge`: verifies caller SPIFFE → runs PolicyEngine against the `energy-token` mint instruction → fetches blockhash → requests Vault signature → submits transaction → records receipt.
7. On-chain: `energy-token::mint_to_wallet` mints GRID to the user's ATA; the transaction signature is written back to Postgres and emitted as an `OrderMatched`-equivalent event for `noti-service`.

### 8.2 Order Submission → Settlement

1. User posts a limit order via the UI → APISIX → `trading-service` REST.
2. `TradingApi` validates JWT, checks escrow balance, persists order to `trading_orders`.
3. `TradingMatcher` consumes new-order events from Redis Streams, applies CDA logic against the zone's order book, and produces match pairs.
4. Match pairs are settled in batches via `trading::execute_batch` (high throughput) or per-match via `match_orders` (low latency, dev path).
5. `chain-bridge` validates that the caller (`trading-service/matcher`) is allowed to invoke the `trading` program, signs, submits.
6. On confirmation, `OrderMatched` lands on Kafka → `noti-service` notifies both parties via WebSocket and email.

### 8.3 Failure semantics

- **Vault unavailable** → `chain-bridge` returns `Unavailable` on gRPC, and the NATS message remains unacked. Callers retry; nothing is lost.
- **Chain unavailable** → transactions queue in NATS JetStream. The Chain Bridge re-drains on recovery.
- **Postgres primary failover** → PgBouncer transparently fails over; in-flight writes return `40001` and are retried at the service layer.
- **Single zone overloaded** → only that zone's ingester backpressures; other zones are unaffected (this is the entire reason for partitioning).

## 9. Observability

All services emit OpenTelemetry traces tagged with the caller's SPIFFE identity and the inbound request ID. The collector stack:

- **Prometheus + Grafana** — metrics and dashboards (host, container, application).
- **Tempo** — distributed tracing backend.
- **Loki** — structured log aggregation.
- **Node Exporter + cAdvisor** — host and container resource visibility.

The `request_id_middleware` propagates a correlation ID from the gateway through every service, so a single click in the UI can be traced end-to-end through Trading, Chain Bridge, Vault, and Solana confirmation.

## 10. Deployment Topology

The platform runs as a Docker Compose stack for local development and as a Kubernetes deployment in staging and production. All workloads:

- Mount their SVID from a SPIRE agent sidecar.
- Reach Vault over mTLS with their SPIFFE identity as the auth method.
- Expose `/health`, `/health/live`, and Prometheus `/metrics` endpoints.
- Shut down gracefully on `CancellationToken`, draining in-flight requests before exit.

The Solana node runs as localnet for development, Solana devnet for the hackathon demo, and is targeted at a permissioned Proof-of-Authority L1 (Agave-aligned) with PEA/EGAT/MEA/ERC as validators for the production deployment. Migration triggers for that move are tracked separately.

## 11. Scale Targets

The matching engine is engineered to a three-tier capacity ladder:

| Tier | TPS target | Substrate |
|---|---|---|
| Tier 1 | 10k – 50k | Postgres + Redis Streams |
| Tier 2 | 50k – 200k | Add FoundationDB 7.3+ for settlement durability |
| Tier 3 | 200k+ | Add Redpanda for cross-region event distribution |

Each tier preserves the on-chain settlement contract; only the off-chain matching and durability substrate changes.

---

_Maintained by GridTokenX Platform Engineering. Last revised: June 2026._
