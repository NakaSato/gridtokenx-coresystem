# GridTokenX — System Architecture

> Top-level architecture map for the GridTokenX superproject.
> Per-service internals live in `<service>/ARCHITECTURE.md`. Deep dives in [`docs/`](docs/).
> Last reviewed: 2026-06-07

---

## 1. What This System Is

GridTokenX is a blockchain-backed Peer-to-Peer (P2P) energy trading platform. It bridges
**physical energy infrastructure** (smart meters, solar inverters, EV chargers) with a
**trustless financial market** settled on the Solana blockchain.

The codebase is a **git superproject**: every `gridtokenx-*` service is a git submodule with
its own independent Cargo workspace. There is no root `Cargo.toml`.

## 2. Two Interconnected Platforms

| Aspect | Exchange Platform | Infrastructure Platform |
| :--- | :--- | :--- |
| Primary domain | Financial / trading | Physical / data integrity |
| Blockchain access | Direct (IAM, Trading) | Indirect (signs only) |
| Data direction | Receives validated data | Produces validated data |
| Scaling factor | Trading volume / user count | Device count / telemetry volume |
| Key services | API Services, IAM, Trading | Edge Gateway, Aggregator Bridge |

## 3. Four-Layer Cyber-Physical Model

```
I.   Smart Meter        → Ed25519-sign telemetry at source
II.  Ingestion          → Aggregator Bridge verifies sig → Kafka event log
III. Exchange           → CDA matching engine → atomic settlement gateway
IV.  Distributed Ledger → Solana programs: Registry, Settlement, Energy Asset Ledger
```

## 4. Service Mesh

| Service | Lang | HTTP | gRPC | Role |
| :--- | :--- | :--- | :--- | :--- |
| API Services Orchestrator | Rust | 4000 | — | Public ConnectRPC entry / fan-out |
| IAM Service | Rust | 4010 | 5010 | Identity, wallets, on-chain registration |
| Trading Service | Rust | 4020 | 5020 | CDA matching, settlement |
| Aggregator Bridge | Rust | 4030 | 5030 | Telemetry verify + aggregation |
| Chain Bridge | Rust | — | 5040 | **Only** service touching Solana RPC |
| Noti Service | Rust | — | — | Notification delivery |
| Smartmeter Simulator | Python | — | — | Telemetry generation / load test |

Gateways: **APISIX** `:4001` (user-facing, HTTPS/WSS) · **Envoy** `:4002` (IoT/mTLS edge).

## 5. Hard Architecture Rules

1. **Sync core, async edges** — business logic is synchronous traits; API/persistence/messaging are async.
2. **Dependency direction** — `server → api → logic → persistence → core`. Never reverse.
3. **Blockchain access only via Chain Bridge** — writes publish to NATS JetStream
   (`chain.tx.submit`); reads are gRPC. No service calls Solana RPC directly.
4. **Trait-based DI** — define traits in `core`, implement in `persistence`, wire in `server`.

See [`CLAUDE.md`](CLAUDE.md) for the enforced conventions behind these rules.

## 6. Messaging & Persistence

- **Kafka** — command / market / audit event logs (event sourcing).
- **NATS JetStream** — async on-chain tx submission.
- **RabbitMQ** `:5672` — task queues.
- **Redis** — live pub/sub + telemetry streams.
- **PostgreSQL 17** `:7001` — IAM + Trading relational state.
- **InfluxDB 2.7** — Aggregator Bridge time-series telemetry.
- **ClickHouse** — Trading analytics.

Port scheme: 4000s gateways · 5000s gRPC mesh · 7000s persistence · 9000s messaging.

## 7. Documentation Map

| Doc | Covers |
| :--- | :--- |
| [`docs/design-docs/`](docs/design-docs/) | Why the system is shaped this way |
| [`docs/product-specs/`](docs/product-specs/) | What user-facing features must do |
| [`docs/exec-plans/`](docs/exec-plans/) | Active and completed execution plans |
| [`docs/references/`](docs/references/) | External reference material (llms.txt, vendor docs) |
| [`docs/generated/`](docs/generated/) | Auto-generated artifacts (DB schema) |
| [`docs/glossary.md`](docs/glossary.md) | Domain terms (GRID, GRX, REC, VPP, CDA, PDA) |

## 8. Component Architecture Docs

Per-component `ARCHITECTURE.md` — each documents only that folder. Submodule docs live in the
submodule; commit them there, then bump the pointer here.

| Component | Doc | Kind |
| :--- | :--- | :--- |
| Anchor programs (on-chain) | [`gridtokenx-anchor/ARCHITECTURE.md`](gridtokenx-anchor/ARCHITECTURE.md) | Solana/Anchor |
| Blockchain core (shared lib) | [`gridtokenx-blockchain-core/ARCHITECTURE.md`](gridtokenx-blockchain-core/ARCHITECTURE.md) | Rust crate |
| Chain Bridge | [`gridtokenx-chain-bridge/ARCHITECTURE.md`](gridtokenx-chain-bridge/ARCHITECTURE.md) | Rust service |
| IAM Service | [`gridtokenx-iam-service/ARCHITECTURE.md`](gridtokenx-iam-service/ARCHITECTURE.md) | Rust service |
| Noti Service | [`gridtokenx-noti-service/ARCHITECTURE.md`](gridtokenx-noti-service/ARCHITECTURE.md) | Rust service |
| Aggregator Bridge | [`gridtokenx-aggregator-bridge/ARCHITECTURE.md`](gridtokenx-aggregator-bridge/ARCHITECTURE.md) | Rust service |
| Trading Service | [`gridtokenx-trading-service/ARCHITECTURE.md`](gridtokenx-trading-service/ARCHITECTURE.md) | Rust service |
| Smartmeter Simulator | [`gridtokenx-smartmeter-simulator/ARCHITECTURE.md`](gridtokenx-smartmeter-simulator/ARCHITECTURE.md) | Python |
| Trading frontend | [`gridtokenx-trading/ARCHITECTURE.md`](gridtokenx-trading/ARCHITECTURE.md) | Next.js |
| WASM module | [`gridtokenx-wasm/ARCHITECTURE.md`](gridtokenx-wasm/ARCHITECTURE.md) | Rust→WASM |
| Explorer frontend | [`gridtokenx-explorer/README.md`](gridtokenx-explorer/README.md) | Next.js (README only) |
| Telemetry (shared lib) | [`gridtokenx-telemetry/ARCHITECTURE.md`](gridtokenx-telemetry/ARCHITECTURE.md) | Rust crate |
| APISIX gateway (user) | [`apisix_conf/ARCHITECTURE.md`](apisix_conf/ARCHITECTURE.md) | Gateway config |
| Envoy gateway (edge) | [`envoy_conf/ARCHITECTURE.md`](envoy_conf/ARCHITECTURE.md) | Gateway config (dev stub) |
