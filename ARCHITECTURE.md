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
| Noti Service | Rust | 4060 | 5060 | Notification delivery |
| Smartmeter Simulator | Python | — | — | Telemetry generation / load test |

Gateways: **APISIX** `:4001` (user-facing, HTTPS/WSS). IoT/edge telemetry ingresses directly to the Aggregator Bridge IoT gateway (Ed25519-signed payloads); there is no separate edge proxy.

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
- **Redis** `:7010` — live pub/sub + telemetry streams.
- **PostgreSQL 17** `:7001` — IAM + Trading relational state (single primary).
- **[PgDog](https://docs.pgdog.dev)** `:7003` — sole Postgres connection pooler (Rust; replaced PgBouncer); all services connect in-network via `pgdog:6432`.

Port scheme: 4000s gateways · 5000s gRPC mesh · 7000s persistence · 9000s messaging.

## 7. Documentation Map

| Doc | Covers |
| :--- | :--- |
| [`docs/design-docs/`](docs/design-docs/) | Why the system is shaped this way |
| [`docs/product-specs/`](docs/product-specs/) | What user-facing features must do |
| [`docs/exec-plans/`](docs/exec-plans/) | Active and completed execution plans |
| [`docs/references/`](docs/references/) | External reference material (llms.txt, vendor docs) |
| [`docs/generated/`](docs/generated/) | Auto-generated artifacts (DB schema) |
| [`docs/benchmark-best-practices.md`](docs/benchmark-best-practices.md) | Benchmark methodology & roadmap (systems + P2P-energy metrics) |
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
| WASM module | [`gridtokenx-trading/wasm/ARCHITECTURE.md`](gridtokenx-trading/wasm/ARCHITECTURE.md) | Rust→WASM (in trading frontend) |
| Explorer frontend | [`gridtokenx-explorer/README.md`](gridtokenx-explorer/README.md) | Next.js (README only) |
| Telemetry (shared lib) | [`gridtokenx-telemetry/ARCHITECTURE.md`](gridtokenx-telemetry/ARCHITECTURE.md) | Rust crate |
| APISIX gateway (user) | [`apisix_conf/ARCHITECTURE.md`](apisix_conf/ARCHITECTURE.md) | Gateway config |

### 8.1 meter→solana settlement trace

The verified end-to-end generation-mint path `smartmeter → aggregator-bridge →
blockchain-core → chain-bridge → solana`. Hardening notes + gap closure in
[`docs/plans/meter-to-solana-hardening.md`](docs/plans/meter-to-solana-hardening.md).

| Hop | Where | What happens |
| :--- | :--- | :--- |
| Ingest + verify | `gridtokenx-aggregator-bridge/crates/aggregator-persistence/src/infra/crypto.rs` | Ed25519 device sig verified vs Redis pubkey; fail-closed on Redis-down. |
| Aggregate → mint | `gridtokenx-aggregator-bridge/crates/aggregator-api/src/ingester/settlement_engine.rs:235` | 15-min bins batched into `MintRecipient`s; routed to Chain Bridge when `MINT_VIA_CHAIN_BRIDGE=true`. |
| Path select | `gridtokenx-aggregator-bridge/src/main.rs` | Resolves `settlement_path{path="nats|grpc|http"}` gauge; warns on silent gRPC degrade (NATS_URL unset). |
| NATS publish | `gridtokenx-blockchain-core/src/rpc.rs:205`, `gridtokenx-blockchain-core/src/rpc/nats_provider.rs:127` | `NATS_URL` set ⇒ signed `chain.tx.submit` envelope; else gRPC-only fallback. |
| Envelope auth | `gridtokenx-chain-bridge/crates/chain-bridge-api/src/nats_consumer/auth.rs:105` | cert→CA→SPIFFE SAN→P256 sig; enforced when `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true` (else log-only + `nats_auth_*` metrics). |
| Sign + submit | `gridtokenx-chain-bridge/crates/chain-bridge-api/src/nats_consumer/consumer.rs` | RBAC → dedup `claim_or_replay` → Vault Transit sign → Solana submit. Single signing path. |
