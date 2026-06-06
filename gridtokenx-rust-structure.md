# GridTokenX Rust Backend Project Structure for National-Scale Infrastructure

**Tailored to your existing repo conventions** — Built on the patterns already proven in `gridtokenx-iam-service` and `gridtokenx-noti-service` (the 4-layer `*-core` / `*-persistence` / `*-logic` / `*-api` split), and the chain-bridge `rpc::{account, instructions, on_chain, ...}` submodule pattern. The design scales from Koh Tao islanded pilot through national PEA/MEA/EGAT deployment without breaking any existing service boundaries.

---

## TL;DR

- **Keep your current top-level multi-repo layout** (`gridtokenx-iam-service/`, `gridtokenx-chain-bridge/`, `gridtokenx-oracle-bridge/`, etc.) — each repo is a self-contained Cargo workspace. This matches what you have working today and avoids a disruptive monorepo migration.
- **Standardize every service on the 4-layer crate pattern** you already use in IAM and Notification: `{svc}-core` (no async, pure domain), `{svc}-persistence` (DB/Redis/MQ adapters), `{svc}-logic` (orchestration), `{svc}-api` (transport: connectrpc + buffa + axum). This is your proven convention — apply it consistently to oracle-bridge, trading-service, and settlement-engine.
- **Promote `gridtokenx-blockchain-core` to a true shared kernel** distributed via Cargo's `[patch.crates-io]` or a private git registry (you already depend on it across IAM, Notification, and chain-bridge). It's the cross-repo lingua franca for Solana types, shard math (`shard_for`), and the IAM CLAUDE.md invariants.
- **Scale in three tiers** mapped to concrete code changes: Tier 1 (Koh Tao, 10k TPS — current state, modular monoliths per service), Tier 2 (multi-province, 50k TPS — extract zone-sharded matching engine, NATS leaf nodes at substation edges), Tier 3 (national, 200k+ TPS — database-per-service with Citus, NATS supercluster, SPIFFE federation across PEA/MEA/EGAT trust domains).
- **Close the three identified chain-bridge gaps** before ERC Sandbox Phase 2: instruction-level transaction policy engine (declarative DSL), tamper-evident audit log (hash-chain + Merkle-anchor to Solana), and pre-sign transaction simulation (LiteSVM in-process).

---

## 1. Top-Level Repository Layout (Your Current Reality)

Your existing layout is already a polyrepo of independent Cargo workspaces glued together by Docker Compose, with `gridtokenx-blockchain-core` and `gridtokenx-anchor` as the shared kernel. Keep it. The recommendation is to **standardize the inside of each service**, not to consolidate the repos.

```
gridtokenx/                                    # superproject (you are here)
├── docker-compose.yml                          # service orchestration (Tier 1)
├── docker-compose.db.yml                       # DB-only override for local dev
├── apisix_conf/                                # API gateway config (edge routing)
├── monitoring/                                 # Prometheus/Grafana/Tempo/Loki stack
├── scripts/                                    # cross-repo dev tooling
├── docs/                                       # ADRs, runbooks, CLAUDE.md invariants
│
├── gridtokenx-blockchain-core/                 # ★ SHARED KERNEL (Solana types, shard math)
├── gridtokenx-anchor/                          # ★ SHARED KERNEL (Anchor program IDLs + bindings)
├── gridtokenx-wasm/                            # ★ SHARED KERNEL (WASM compute modules)
│
├── gridtokenx-chain-bridge/                    # Vault signing + Solana submission
├── gridtokenx-iam-service/                     # identity, RBAC, SPIFFE issuance
├── gridtokenx-oracle-bridge/                   # IoT/meter ingestion (DLMS, OCPP, SunSpec, OpenADR)
├── gridtokenx-trading-service/                 # CDA order matching + zone markets
├── gridtokenx-trading/                         # (legacy — consolidate into trading-service)
├── gridtokenx-noti-service/                    # email, websocket, push notifications
├── gridtokenx-explorer/                        # blockchain explorer (read model)
├── gridtokenx-smartmeter-simulator/            # GLM-based AMI simulator
└── gridtokenx-api/ (to be added)               # public-facing edge API
```

**Decision: keep polyrepo, standardize internals.** A monorepo migration is a major project — your current setup works. The leverage is in making every service look the same inside, so a developer who knows IAM can navigate trading-service in 10 minutes.

---

## 2. The 4-Layer Crate Pattern (Your Existing Convention, Generalized)

Every service workspace follows the same shape. This is what you already do in `gridtokenx-iam-service` and `gridtokenx-noti-service` — formalized as the project standard.

```
gridtokenx-{service}/
├── Cargo.toml                       # virtual workspace; [workspace.dependencies] single source of truth
├── Cargo.lock                       # committed (reproducible builds + accurate SBOM)
├── rust-toolchain.toml              # pinned compiler for reproducibility
├── deny.toml                        # cargo-deny: license/advisory/ban policy
├── supply-chain/                    # cargo-vet audit records (Tier 2+)
├── README.md
├── CLAUDE.md                        # service-specific invariants (you already use these)
├── SKILL.md                         # subsystem expert knowledge
├── migrations/                      # sqlx migrations (if persistent)
├── proto/                           # .proto files + buf.yaml (input to build.rs)
├── crates/
│   ├── {svc}-core/                  # ① DOMAIN: types, traits, errors. NO tokio, NO sqlx, NO transport
│   ├── {svc}-persistence/           # ② ADAPTERS: sqlx, redis, kafka, lapin, lettre impls of -core traits
│   ├── {svc}-logic/                 # ③ ORCHESTRATION: use cases that compose -core traits via -persistence
│   ├── {svc}-api/                   # ④ TRANSPORT: axum + connectrpc + buffa handlers, telemetry, main
│   └── {svc}-protocol/              # generated protobuf/buffa code (referenced by -api, sometimes -logic)
└── tests/                           # cross-crate integration + LiteSVM (for blockchain-touching services)
```

### 2.1 Layer responsibilities (the contract)

| Layer | Owns | Forbidden imports | Example crates |
|---|---|---|---|
| **`{svc}-core`** | Domain types, value objects, traits (ports), error enums (`thiserror`), `Permission` / `Role` / business invariants | `tokio`, `sqlx`, `redis`, `rdkafka`, `lapin`, `axum`, `connectrpc`, `tonic` | `serde`, `chrono`, `uuid`, `thiserror`, `async-trait`, `gridtokenx-blockchain-core` |
| **`{svc}-persistence`** | Trait *implementations*: `PostgresUserRepo`, `RedisCache`, `KafkaProducer`, `RabbitMQDispatcher`, `LettreSmtpProvider`. One adapter = one impl block. | `axum`, `connectrpc`, business logic that isn't I/O | `{svc}-core`, `sqlx`, `redis`, `rdkafka`, `lapin`, `lettre`, `tera` (for noti templates) |
| **`{svc}-logic`** | Use cases / orchestrators (e.g., `NotificationOrchestrator`, `MatchingOrchestrator`). Composes ports from `-core` using adapters from `-persistence`. | `axum`, `tonic::transport`, raw connectrpc handlers | `{svc}-core` (with `mocks` feature), `{svc}-persistence`, `{svc}-protocol`, `tokio`, `tracing` |
| **`{svc}-api`** | HTTP/gRPC handlers, middleware, OpenAPI/proto wiring, telemetry init, `main.rs` | Business logic (must delegate to `-logic`) | `{svc}-core`, `{svc}-logic`, `{svc}-protocol`, `axum`, `connectrpc`, `buffa`, `utoipa`, `tower-http` |
| **`{svc}-protocol`** | `build.rs` codegen for `.proto`; re-exports generated types. Pure DTO crate. | Everything else | `prost`/`buffa`, `tonic-build` |

### 2.2 The dependency-inversion rule (already in your IAM crate graph)

```
{svc}-api  ─────────┐
       │            ▼
       └──► {svc}-logic ──► {svc}-persistence
                  │                │
                  └──► {svc}-core ◄┘
```

Dependencies point *inward* toward `-core`. A change in `-api` (new gRPC endpoint) does not force a change in `-core`. A change in `-persistence` (Postgres → Citus) does not touch `-logic`. This is the same pattern your `iam-logic/Cargo.toml` already enforces: `iam-logic` depends on `iam-core` (with `mocks` feature for tests), `iam-persistence`, and `iam-protocol`, but `iam-core` depends on nothing from the other layers.

### 2.3 The `mocks` feature pattern (you already use this)

In `iam-core/Cargo.toml`:
```toml
[features]
mocks = ["mockall"]
```

Then `iam-logic` consumes its own dependencies' mocks:
```toml
iam-core = { workspace = true, features = ["mocks"] }
```

This is the right pattern. Generalize it: every `{svc}-core` exposes a `mocks` feature gated on `mockall`. Every `{svc}-logic` integration test uses it.

---

## 3. Per-Service Application of the Pattern

### 3.1 `gridtokenx-iam-service` — your reference (already correct)

```
gridtokenx-iam-service/
├── crates/
│   ├── iam-core/               # Role, Permission, User, JWT claims, traits, ApiError
│   │   └── src/domain/identity/{roles,users,sessions}.rs
│   ├── iam-persistence/        # PostgresUserRepo, RedisSessionStore, KafkaAuditPublisher
│   ├── iam-logic/              # AuthService, RegistrationOrchestrator, calls gridtokenx-blockchain-core
│   ├── iam-protocol/           # generated identity.v1 + auth.v1 types
│   └── iam-api/                # axum routes, connectrpc service, JWT middleware
└── migrations/
```

No changes recommended.

### 3.2 `gridtokenx-noti-service` — your reference (already correct)

```
gridtokenx-noti-service/
├── crates/
│   ├── noti-core/              # Notification, Channel, Status, traits, NotiError
│   ├── noti-persistence/       # SqlxNotiRepo, RedisCache, RabbitMQ DLX, SMTP, Tera templates
│   ├── noti-logic/             # NotificationOrchestrator (your six-layer dispatch pipeline)
│   ├── noti-protocol/          # generated noti.v1 types
│   └── noti-api/               # axum + connectrpc + websocket ConnectionManager
└── migrations/
```

No changes recommended.

### 3.3 `gridtokenx-chain-bridge` — refactor target

**Current state** (from your `src/rpc.rs`): a flat module layout — `rpc::{account, instructions, on_chain, priority_fee, token, transaction, utils, nats_provider, nats_schema}`. Works for one binary, but as you add the three pre-production features (policy engine, audit log, pre-sign sim), the flat layout will rot.

**Recommended refactor**:
```
gridtokenx-chain-bridge/
├── proto/chain.v1.proto
├── crates/
│   ├── chain-bridge-core/        # ① SignerPort, ChainClientPort, NoncePort, AuditPort traits
│   │   │                         #   TxPolicy, NonceAllocation, AuditEntry (newtype IDs)
│   │   └── src/
│   │       ├── ports.rs
│   │       ├── policy.rs         # ← new: declarative policy DSL types (closes Gap #1)
│   │       ├── audit.rs          # ← new: AuditEntry, hash-chain types (closes Gap #2)
│   │       ├── nonce.rs
│   │       └── error.rs
│   ├── chain-bridge-persistence/ # ② VaultTransitSigner, NatsProvider, PostgresAuditStore
│   │   └── src/
│   │       ├── vault_signer.rs   # implements SignerPort
│   │       ├── solana_client.rs  # implements ChainClientPort (current on_chain.rs)
│   │       ├── nats_provider.rs  # current nats_provider.rs
│   │       ├── postgres_audit.rs # ← new: AuditPort impl with hash-chain
│   │       └── litesvm_sim.rs    # ← new: PreSignSimulatorPort impl (closes Gap #3)
│   ├── chain-bridge-logic/       # ③ SubmitTransactionOrchestrator, AuditMerkleAnchor scheduler
│   │   └── src/
│   │       ├── submit.rs         # the saga: policy check → simulate → sign → submit → audit
│   │       ├── policy_engine.rs  # evaluates TxPolicy against an instruction list
│   │       └── audit_anchor.rs   # periodic Merkle-root anchoring to Solana
│   ├── chain-bridge-protocol/    # generated chain.v1 from proto/
│   └── chain-bridge-api/         # connectrpc ChainBridgeService impl, main.rs, telemetry init
├── migrations/                   # audit_log table, nonce_allocations table
└── tests/                        # LiteSVM simnet integration
```

**Why this matters**: the three gaps are not separable. The pre-sign simulator (`litesvm_sim.rs` in persistence) needs the policy engine (`policy_engine.rs` in logic) to know *what* to simulate, and the audit log (`postgres_audit.rs` + `audit_anchor.rs`) needs both to record what passed/failed. The crate boundary makes the data flow explicit: `submit.rs` calls policy → sim → sign → submit → audit, all via traits in `-core`.

### 3.4 `gridtokenx-oracle-bridge` — refactor target

**Current state** (from your `src/main.rs`): a single-crate flat module layout (`aggregator`, `auth`, `dispatch`, `grpc`, `handlers`, `infra`, `ingester`, `metrics`, `middleware`, `models`, `protocol`, `standards`, `router`, `state`, `telemetry`, `utils`, `zk`). It works, but `state.rs` is now an `AppState` god-struct with 12 fields including Kafka producer, RabbitMQ producer, signature verifier, settlement signer, meter registry, and four protocol stacks. That's the "God crate" anti-pattern starting to form.

**Recommended refactor**:
```
gridtokenx-oracle-bridge/
├── crates/
│   ├── oracle-core/              # DeviceReading, DeviceMetrics, ProtocolStack trait, SignatureVerifier trait, MeterRegistry trait
│   ├── oracle-persistence/       # Kafka/RabbitMQ producers, Redis cache, Postgres meter registry, Ed25519 verifier
│   ├── oracle-logic/             # ZoneEventIngester, BatchWorker, DispatchEngine, ZkProver
│   ├── oracle-protocol/          # generated oracle.v1, dispatch.v1
│   ├── oracle-stacks/            # NEW: DLMS, OCPP, SunSpec, OpenADR, IEEE 2030.5 stack implementations
│   │                             #      (each implements ProtocolStack from oracle-core)
│   └── oracle-api/               # axum routes + connectrpc OracleServiceImpl + main.rs
└── tests/
```

The key move is **extracting `oracle-stacks` as its own crate**: protocol stacks have different update cadences (IEEE 2030.5 evolves separately from DLMS/COSEM) and benefit from being a swappable adapter set. The `AppState` shrinks because protocol stacks become an `Arc<dyn ProtocolStackRegistry>` injected at the API layer.

### 3.5 `gridtokenx-trading-service` — refactor target (the hottest path)

This is where scale matters most: zone-sharded order matching at 200k+ TPS national load. Apply the 4-layer pattern, plus a **`trading-matching` core engine crate** kept synchronous and CPU-pinned (TigerBeetle-style):

```
gridtokenx-trading-service/
├── crates/
│   ├── trading-core/             # Order, ZoneMarket, MatchPair, MatchingPort trait
│   ├── trading-matching/         # ← single-threaded, pure, deterministic CDA engine (no_std-compatible)
│   │                             #   Same code can run inside an Anchor program for batch settlement
│   ├── trading-persistence/      # Postgres (trading_orders, order_matches), Redis order book cache
│   ├── trading-logic/            # ZoneShardingOrchestrator, BatchClearingScheduler, AnchorSettlementWorker
│   ├── trading-protocol/         # generated trading.v1
│   └── trading-api/              # connectrpc TradingService, main.rs
└── tests/
```

The `trading-matching` crate is the GridTokenX equivalent of TigerBeetle's deterministic state machine: pure, single-threaded, heavily property-tested with `proptest`, and runnable both in the off-chain service (high throughput) and within the on-chain `programs/trading` Anchor program (low throughput, authoritative settlement). This is the practical realization of the "no_std boundary" — same domain logic, two compilation targets.

### 3.6 `gridtokenx-api` — to be added (national-scale edge)

A stateless, horizontally-scaled edge service. UPI-style: a thin switch routing between internal services. Follows the same 4-layer pattern, where `-logic` becomes a router/composition layer rather than a stateful orchestrator.

---

## 4. The Shared Kernel: `gridtokenx-blockchain-core`

You already depend on this across IAM, Notification, and chain-bridge (every `Cargo.toml` shows `gridtokenx-blockchain-core.workspace = true`). It's the de-facto shared kernel.

### 4.1 Promote it to a first-class internal crate

```
gridtokenx-blockchain-core/
├── Cargo.toml                    # publish to private registry OR use [patch.crates-io]
├── src/
│   ├── lib.rs
│   ├── shard.rs                  # the invariant: shard_for(pubkey) = pubkey.to_bytes()[0] % 16
│   ├── pdas.rs                   # canonical PDA derivations (registry, market, trade_record, ...)
│   ├── ids.rs                    # MeterId, UserId, ZoneId newtypes
│   ├── units.rs                  # KWh, GRID, GRX, Lamports as typed money/energy values
│   ├── policy.rs                 # cross-service TxPolicy types (chain-bridge consumes)
│   └── audit.rs                  # AuditEntry root types (chain-bridge produces; explorer consumes)
└── features/
    ├── default = ["std"]
    ├── std                       # std for service code
    └── mocks                     # mockall mocks for downstream tests
```

### 4.2 Distribution options (pick one)

| Option | When to use | Tradeoff |
|---|---|---|
| **Path deps with `[patch.crates-io]` in each service Cargo.toml** | Today, all repos on same dev machine | Simplest. Breaks for CI on different repos. |
| **Private cargo registry (e.g. cloudsmith, kellnr, or self-hosted)** | Tier 2 (multi-province) | Real versioning, semver enforcement, CI-friendly. **Recommended target.** |
| **Git dependency with tag pinning** | Bridging today → Tier 2 | Works without infra; harder to enforce semver. **Recommended now.** |
| **Cargo workspace across repos via `members = ["../gridtokenx-blockchain-core"]`** | Avoid | Brittle, breaks CI isolation. |

**Recommendation**: Move to a **git-tagged dependency** now (`gridtokenx-blockchain-core = { git = "ssh://git@github.com/.../gridtokenx-blockchain-core.git", tag = "v0.4.0" }`); migrate to a private cargo registry at Tier 2 when more than 4 engineers are touching it concurrently.

### 4.3 The CLAUDE.md invariants live here

Your chain-bridge `src/rpc.rs` already references "superproject CLAUDE.md invariant #3" (the `shard_for` rule). The shard math itself should *live* in `gridtokenx-blockchain-core/src/shard.rs` so chain-bridge, IAM, and the Registry Anchor program all import the same single source of truth. Today the chain-bridge has its own `fn shard_for(key: &Pubkey) -> u8 { key.to_bytes()[0] % 16 }` — that's invariant drift waiting to happen.

---

## 5. The Workspace `Cargo.toml` Template

Every service uses this pattern (verbatim from your IAM service, generalized):

```toml
# gridtokenx-{service}/Cargo.toml
[workspace]
resolver = "2"
members = ["crates/*"]

[workspace.package]
version = "0.4.0"
edition = "2021"
rust-version = "1.83"
license = "Proprietary"
repository = "https://github.com/.../gridtokenx-{service}"

[workspace.dependencies]
# --- Async runtime + concurrency ---
tokio = { version = "1.42", features = ["full"] }
tokio-util = { version = "0.7", features = ["rt"] }
futures = "0.3"
async-trait = "0.1"

# --- Transport (the locked-in stack) ---
connectrpc = "0.4"
buffa = "0.4"
axum = { version = "0.7", features = ["macros"] }
tower = "0.5"
tower-http = { version = "0.6", features = ["trace", "cors", "compression-gzip"] }
http = "1"

# --- Persistence (the locked-in stack) ---
sqlx = { version = "0.8", features = ["runtime-tokio-rustls", "postgres", "uuid", "chrono", "json", "migrate"] }
redis = { version = "0.27", features = ["tokio-comp", "connection-manager"] }
rdkafka = { version = "0.36", features = ["cmake-build"] }
lapin = "2.5"

# --- Solana ---
solana-sdk = "1.18"

# --- Shared kernel ---
gridtokenx-blockchain-core = { git = "ssh://git@github.com/.../gridtokenx-blockchain-core.git", tag = "v0.4.0" }

# --- Identity & crypto ---
jsonwebtoken = "9"
bcrypt = "0.16"
argon2 = "0.5"
sha2 = "0.10"
rand = "0.8"
bs58 = "0.5"
rustls = "0.23"

# --- Templating, mail ---
lettre = { version = "0.11", features = ["tokio1-rustls-tls", "smtp-transport"] }
tera = "1.20"

# --- Telemetry ---
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
metrics = "0.24"
metrics-exporter-prometheus = "0.16"
opentelemetry = "0.27"
opentelemetry-otlp = { version = "0.27", features = ["grpc-tonic"] }

# --- Errors, IDs, time ---
anyhow = "1"
thiserror = "2"
uuid = { version = "1", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
rust_decimal = { version = "1", features = ["serde"] }

# --- Serde ---
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# --- Config ---
config = "0.14"
dotenvy = "0.15"

# --- API docs ---
utoipa = { version = "5", features = ["axum_extras", "uuid", "chrono"] }

# --- Concurrency primitives ---
dashmap = "6"

# --- Test ---
mockall = "0.13"
rstest = "0.23"
tokio-test = "0.4"
axum-test = "16"

[workspace.lints.rust]
unsafe_code = "forbid"
missing_debug_implementations = "warn"
unused_must_use = "deny"

[workspace.lints.clippy]
pedantic = { level = "warn", priority = -1 }
nursery = { level = "warn", priority = -1 }
unwrap_used = "deny"        # banned in production code
expect_used = "warn"
panic = "warn"
todo = "warn"
```

This is **the** workspace template. Copy it into each service repo, change names, and you're done.

---

## 6. Cross-Service Contracts

### 6.1 Protobuf / ConnectRPC schema management

You're already using `connectrpc` + `buffa`. Centralize proto governance:

```
gridtokenx-proto-shared/             # NEW: cross-service proto registry repo
├── buf.yaml
├── buf.gen.yaml
├── proto/
│   ├── gridtokenx/
│   │   ├── chain/v1/chain.proto              # used by chain-bridge, IAM, trading-service
│   │   ├── oracle/v1/oracle.proto            # used by oracle-bridge consumers
│   │   ├── trading/v1/trading.proto          # used by trading-service, api gateway
│   │   ├── iam/v1/identity.proto             # used by all services that authenticate
│   │   ├── noti/v1/noti.proto                # used by services that emit notifications
│   │   └── common/v1/common.proto            # shared scalar types: MeterId, ZoneId, KWh
└── ci/
    └── buf-breaking.yml                       # CI gate: `buf breaking --against .git#branch=main`
```

Each service `Cargo.toml` adds a `build-dependencies` entry that pulls the proto repo as a git submodule or tarball, then `tonic_build` (via the buffa codegen) emits `OUT_DIR/_<svc>_include.rs` that `{svc}-protocol/src/lib.rs` includes — exactly as your oracle-bridge `src/grpc/service.rs` already does:

```rust
pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/_oracle_include.rs"));
    pub use gridtokenx::oracle::v1::*;
}
```

This is your existing pattern. Standardize it.

### 6.2 NATS JetStream subject taxonomy

Hierarchical, versioned, namespaced by service:

```
gtx.<service>.<entity>.<event>.v<N>

Examples (matching what oracle-bridge and chain-bridge already emit):
  gtx.oracle.meter.reading.v1            # oracle-bridge → trading-service, settlement
  gtx.oracle.zone.dispatch.v1            # oracle-bridge → flex dispatch consumers
  gtx.trading.order.matched.v1           # trading-service → chain-bridge
  gtx.trading.batch.cleared.v1           # trading-service → settlement, reporting
  gtx.chain.tx.submitted.v1              # chain-bridge → settlement
  gtx.chain.tx.confirmed.v1              # chain-bridge → settlement, noti
  gtx.chain.audit.anchored.v1            # chain-bridge → explorer (Merkle root)
  gtx.noti.dispatch.requested.v1         # any service → noti-service
  gtx.iam.user.registered.v1             # iam-service → onboarding workflows
```

Stream definitions live in `crates/{svc}-persistence/src/nats_streams.rs` of the producer service. Document them in that service's `SKILL.md`.

### 6.3 Saga / orchestration ownership

| Saga | Orchestrator | Compensations |
|---|---|---|
| User registration | `iam-logic::RegistrationOrchestrator` | Roll back blockchain registration via chain-bridge |
| Meter reading → settlement | `oracle-logic::ZoneEventIngester` → trading → chain-bridge | Re-queue on Kafka consumer failure |
| Order matching → on-chain settlement | `trading-logic::BatchClearingScheduler` | Cancel orders on chain-submission failure |
| Notification dispatch | `noti-logic::NotificationOrchestrator` (already exists in your code) | DLX + retry with `MAX_RETRIES = 5` |

Pattern: every saga uses an idempotency key from `gridtokenx-blockchain-core::ids` and writes to a transactional outbox table in its persistence layer.

---

## 7. The Three-Tier National Scaling Roadmap

### Tier 1 — Koh Tao Pilot (10k–50k TPS, today)

| Concern | Configuration |
|---|---|
| Service count | All 7 services as modular monoliths, each its own Docker container |
| Database | Single Postgres 16 primary + 1 read replica; per-service schemas inside one DB |
| Cache | Single Redis 7 instance |
| Messaging | Single NATS JetStream cluster (Replicas=3) + RabbitMQ for noti DLX |
| Solana | Devnet → permissioned PoA mainnet on Koh Tao |
| Leader election | Postgres advisory lock + fencing token (your existing pattern) |
| Identity | Single SPIFFE trust domain `spiffe://gridtokenx.local` |
| Observability | Prometheus + Grafana + Tempo + Loki (you already have `monitoring/`) |
| Deployment | Docker Compose (`docker-compose.yml`) |

**Code structure**: standardize all 7 services on the 4-layer pattern. Close the 3 chain-bridge gaps. Promote `gridtokenx-blockchain-core` to git-tagged versioning.

### Tier 2 — Multi-Province (50k–200k TPS)

| Concern | Configuration change from Tier 1 |
|---|---|
| Database | **Citus** for trading_orders/order_matches sharding by zone_id; database-per-service for chain-bridge audit log; **TimescaleDB** separate instance for meter telemetry (your `gridtokenx:events:zone_N` Redis streams become long-term storage in Timescale) |
| Cache | Redis Cluster OR DragonflyDB (drop-in) |
| Messaging | NATS leaf nodes at substations (oracle-bridge edge gateways become NATS leaf nodes); hub-cluster mirrors |
| CQRS | Extract reporting-service read model from explorer; populate via NATS events |
| Leader election | Still advisory lock for chain-bridge; consider openraft for trading-service zone shards |
| Identity | SPIFFE federation: `spiffe://pea.gridtokenx.th`, `spiffe://mea.gridtokenx.th` |
| Deployment | Kubernetes per region; ArgoCD GitOps |

**Code structure changes**: 
- `gridtokenx-trading-service`: extract `trading-matching` as a separately deployable shard-worker binary per zone (you have ZoneMarket/ZoneMarketShard infrastructure ready)
- `gridtokenx-blockchain-core`: move to private cargo registry
- New repo: `gridtokenx-api` (stateless edge router)

### Tier 3 — National PEA/MEA/EGAT (200k+ TPS)

| Concern | Configuration change from Tier 2 |
|---|---|
| Database | Database-per-service strict; cross-utility data via NATS events only (X-Road lesson: never share a DB across trust boundaries) |
| Messaging | NATS supercluster with gateways across regions + mirror streams (`MirrorDirect` for read-locality) |
| Solana | Custom L1 fork (Frankendancer-aligned) with PEA/EGAT/MEA/ERC as permissioned validators; chain-bridge speaks Yellowstone gRPC Geyser |
| Compute scaling | Stateless services on K8s HPA; stateful coordinators (chain-bridge nonce manager, settlement-engine) on openraft or etcd consensus |
| Identity | SPIFFE federation across PEA/MEA/EGAT/ERC trust domains with trust bundle exchange |
| Compliance | Air-gapped sovereign cloud option: `cargo vendor`, reproducible builds, `cargo-auditable` SBOMs |

**Code structure changes**:
- `gridtokenx-trading-service` becomes a fleet of zone-sharded matching engines coordinated by openraft
- `gridtokenx-chain-bridge` becomes a Geyser-subscribed validator-co-located service
- New repo: `gridtokenx-federation-broker` (cross-utility data exchange, X-Road pattern)

---

## 8. Build, CI, and Supply Chain

### 8.1 Per-repo CI pipeline

```yaml
# .github/workflows/ci.yml (template, applies to every service repo)
jobs:
  check:
    steps:
      - uses: actions/checkout@v4
      - uses: actions-rust-lang/setup-rust-toolchain@v1
      - uses: Swatinem/rust-cache@v2          # cargo-chef-style layer caching
      - run: cargo fmt --all --check
      - run: cargo clippy --all-targets --all-features -- -D warnings
      - run: cargo test --all-features
      - run: cargo deny check                  # license + advisory + ban
      - run: cargo vet                         # supply-chain audit (Tier 2+)
  proto-breaking:
    if: contains(github.event.pull_request.changed_files, 'proto/')
    steps:
      - run: buf breaking --against '.git#branch=main'
```

### 8.2 Build orchestration recommendation

You're on Cargo workspaces inside each service — keep that. Add at Tier 2:
- **sccache** for compiler-level caching across CI jobs
- **cargo-chef** for Docker layer caching (build deps in cached layer, then app)
- **cargo-nextest** for parallel test execution + changed-crate detection

Do **not** migrate to Bazel. Multiple TigerBeetle-scale Rust teams have published case studies showing the migration is rarely worth it for Rust until you cross 50+ engineers in one repo. You won't be there for years.

### 8.3 Supply-chain hardening (Tier 2+)

```
deny.toml                        # cargo-deny policy — copy across all repos
supply-chain/audits.toml         # cargo-vet audit records
supply-chain/imports.lock        # imported audit policies from trusted parties
```

Required CI gates: `cargo-deny`, `cargo-vet`, `cargo-auditable` (embeds SBOM in production binaries for post-incident analysis), `cosign` (sign container images).

---

## 9. Observability: A Cross-Repo Convention

You already have `tracing` + `metrics-exporter-prometheus` + a `monitoring/` directory with Prometheus/Grafana/Tempo/Loki. Standardize the telemetry init across services as a tiny shared crate:

```
gridtokenx-telemetry/             # NEW: shared telemetry init crate (~200 LOC)
├── src/
│   ├── lib.rs
│   ├── tracing.rs                # init_telemetry(service_name: &str) -> TelemetryGuard
│   ├── metrics.rs                # init_prometheus_exporter() -> PrometheusHandle
│   └── propagation.rs            # NATS header ↔ traceparent injection/extraction
```

Every service's `{svc}-api/src/main.rs` calls `let _g = gridtokenx_telemetry::init("oracle-bridge");` (you already do this in oracle-bridge via your `telemetry::init_telemetry()` — extract it to the shared crate).

**Correlation IDs across NATS**: extract the W3C `traceparent` from gRPC metadata, inject into NATS headers on publish, extract on consume. This is the missing piece in your current stack — a settlement saga spanning oracle-bridge → trading-service → chain-bridge → noti-service currently shows as 4 disconnected traces in Tempo. With proper propagation, it's one trace.

---

## 10. Security at National Scale

### 10.1 SPIFFE/SPIRE federation

| Tier | SPIFFE topology |
|---|---|
| 1 | Single trust domain `spiffe://gridtokenx.local`; SPIRE server in K8s, agents on every node |
| 2 | Per-utility trust domains; nested SPIRE topology (global root + regional intermediates) |
| 3 | Federation between `spiffe://pea.gridtokenx.th`, `spiffe://mea.gridtokenx.th`, `spiffe://egat.gridtokenx.th`, `spiffe://erc.gridtokenx.th`; trust bundles exchanged out-of-band |

### 10.2 Vault Transit topology

- Tier 1: single Vault cluster, `platform_admin` key (you already use this — see your `chain-bridge/src/rpc.rs` comment)
- Tier 2: per-utility Vault namespaces; performance standby replicas in each region
- Tier 3: DR replication clusters; warm-standby promotion; pin Vault version against the known ed25519 prehash regression (issue #31574)

### 10.3 Tamper-evident audit log (closing chain-bridge Gap #2)

`chain-bridge-core/src/audit.rs`:
```rust
pub struct AuditEntry {
    pub seq: u64,
    pub timestamp: i64,
    pub actor: SpiffeId,
    pub action: String,
    pub resource: ResourceRef,
    pub metadata: serde_json::Value,
    pub prev_hash: [u8; 32],
    pub entry_hash: [u8; 32],   // = SHA256(seq || timestamp || actor || action || resource || metadata || prev_hash)
}
```

`chain-bridge-logic/src/audit_anchor.rs`: every N minutes, build a Merkle tree of recent entry hashes and submit the root to a dedicated Anchor program (`audit_anchor`). The Merkle proof for any entry can then be verified against the on-chain root. This is the natural fit given you already have 10 Anchor programs and Switchboard TEE oracles.

---

## 11. Anti-Patterns to Avoid

1. **God `AppState` struct** — your oracle-bridge `src/state.rs::AppState` is already at 12 fields. Split into `IngressState`, `DispatchState`, `BlockchainState` injected separately.
2. **Async in `-core`** — `tokio::sync::RwLock` in a domain crate is a smell. Use `parking_lot::RwLock` if you need sync mutability, or move it to `-persistence`.
3. **Proto types leaking into `-logic`** — always map prost/buffa DTOs to `-core` domain types in the `-api` handler. Your IAM service does this correctly; your chain-bridge has some drift (proto types reach `transaction.rs`).
4. **Invariant duplication** — `shard_for` is defined in your chain-bridge AND the Registry Anchor program. Move it to `gridtokenx-blockchain-core::shard` and import in both.
5. **Premature microservice split** — don't extract `trading-matching` as a separate binary until Tier 2 load justifies it. Today it's a crate; tomorrow it's a deployable.
6. **Bare advisory lock for leadership** — Postgres advisory locks alone don't guarantee exactly-one-writer under network partitions. Always pair with a fencing token enforced by the protected resource.
7. **`unwrap()` in production code** — your workspace lints should `deny` it. Today you have `unwrap_or_else` patterns in `oracle-bridge/src/main.rs` for env vars; those are fine, but production hot paths should not have them.

---

## 12. Migration Roadmap

| Phase | Target | Concrete deliverables |
|---|---|---|
| **0 — Today** | Koh Tao monolithic services | Status: working. IAM and Notification use 4-layer; chain-bridge and oracle-bridge are flat. |
| **1 — PEA Hackathon** | Standardize internal layouts | Refactor `chain-bridge` to 4-layer + close 3 gaps. Refactor `oracle-bridge` to extract `oracle-stacks` crate. Extract `gridtokenx-telemetry` shared crate. |
| **2 — TED Fund** | Shared kernel + supply chain | Move `gridtokenx-blockchain-core` to git-tagged dep. Add `cargo-deny`, `cargo-vet`, `cargo-auditable` across all repos. Centralize `gridtokenx-proto-shared`. |
| **3 — ERC Sandbox Phase 2** | Audit + compliance surface | Tamper-evident audit log live; SPIFFE/SPIRE single trust domain in K8s; Merkle anchor program deployed. |
| **4 — Multi-province (Tier 2)** | Scale-out architecture | Citus on trading DB; TimescaleDB for meter telemetry; NATS leaf nodes at substations; Linkerd service mesh; `gridtokenx-api` edge service. |
| **5 — National (Tier 3)** | Sovereign infrastructure | SPIFFE federation across PEA/MEA/EGAT; database-per-service; NATS supercluster + mirror streams; openraft consensus for stateful coordinators; potential Solana L1 fork. |

---

## 13. Open Questions

1. **`gridtokenx-trading` vs `gridtokenx-trading-service`** — you have both repos. The legacy one should be consolidated into trading-service before Tier 2; the split is currently an invariant-drift risk.
2. **`gridtokenx-explorer` vs reporting-service** — is the explorer the read model, or do you need a separate reporting service? Recommend: explorer = public-facing read UI; reporting-service = internal analytics. Different security postures.
3. **WASM compute (`gridtokenx-wasm`)** — what runs WASM today? If it's meter-side compute (NILM inference), it belongs as a sub-crate of oracle-bridge. If it's on-chain compute supplementing Anchor, it's its own concern. Worth a separate ADR.
4. **Federation broker for cross-utility data** — at what tier do we need an X-Road-style broker? My recommendation: Tier 3, when ERC mandates cross-utility data exchange.
5. **The 3 chain-bridge pre-production gaps** — the policy DSL needs a design decision (declarative YAML rules vs. Rust functions vs. WASM-loaded plugins). I'd start with declarative YAML evaluated by a small rule engine in `chain-bridge-logic/src/policy_engine.rs`; revisit if expressiveness needs grow.
