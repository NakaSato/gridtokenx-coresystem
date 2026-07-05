# GridTokenX — System Architecture

> Top-level architecture map for the GridTokenX superproject.
> Per-service internals live in `<service>/ARCHITECTURE.md`. Deep dives in [`docs/`](docs/).
> Last reviewed: 2026-06-22

---

> **Scope (v3):** GridTokenX is a **software co-simulation study** of a consortium energy
> settlement protocol, not a deployed production system. No claim here implies live operation,
> regulatory approval, or production readiness.
> See [`docs/master-architecture-v3.md`](docs/master-architecture-v3.md) — the authoritative
> spec that governs this codebase.
>
> **Status tags used throughout this repo:**
> **(impl)** implemented in the current codebase ·
> **(sim)** runs on localnet / LiteSVM only ·
> **(designed)** specified, not yet built ·
> **(extension)** beyond the official ERC framework

---

## 1. What This System Is

GridTokenX is a **co-simulation study** of a blockchain-backed consortium energy settlement
protocol for the Thai P2P energy market. It is built on Solana/Anchor (permissioned SVM,
localnet / Surfpool in-memory), not a deployed cluster.

**Why a blockchain — stated up front:** the ledger is justified for exactly one function:
**settlement of trades and related value transfers among parties that do not fully trust one
another.** It is not justified as a database, a control system, or a general data-integrity
layer. See [docs/master-architecture-v3.md §I](docs/master-architecture-v3.md) for the full
justification and concessions.

**Two services, one dividing line — who settles the money:**

| Service | Chain role | Payer → payee | Blockchain required? |
| :--- | :--- | :--- | :--- |
| **Trade service** — P2P energy + REC | **Settlement layer** (atomic swap) | peer → peer (distrusting) | ✅ Yes |
| **DR service** — demand response record | **Record layer** (audit trail only) | state fund → participant | ❌ Not required (reuses platform) |

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

## 3. Five-Layer Architecture (v3)

From [`docs/master-architecture-v3.md §III`](docs/master-architecture-v3.md):

| Layer | Purpose | Status |
| :--- | :--- | :--- |
| **L5 Governance & audit** | Consortium thresholds, ERC observation, tamper-evident log | (designed) — hash-chained audit log: gap |
| **L4 Conservation** | Dual-Tracker: trade + REC + DR within physical capacity | (designed) (extension) |
| **L3 Settlement rails** | Rail A: energy + REC **(impl core)**; Rail B: demand response **(designed)** | mixed |
| **L2 Oracle integrity** | TEE attestation + Merkle batch; makes data verifiable without trusting one custodian | (designed); AMI/oracle path **(impl)** |
| **L1 Foundation** | Vault signing, mTLS, single signing path, Sealevel PDAs, NATS write-ahead | **(impl)**; 3 gaps open (see §III.1) |

### Four-Layer Cyber-Physical Model (unchanged)

```
I.   Smart Meter        → Ed25519-sign telemetry at source
II.  Ingestion          → Aggregator Bridge verifies sig → Kafka event log
III. Exchange           → CDA matching engine → atomic settlement gateway
IV.  Distributed Ledger → Solana programs: Registry, Settlement, Energy Asset Ledger
```

### Build Sequence (v3 §VII)

1. Close L1 foundation gaps: hash-chained audit log · instruction-level parameter policy · pre-sign LiteSVM simulation default-on
2. Harden L2 oracle integrity (TEE + Merkle); name meter-level boundary as future work
3. Refactor Rail A (energy + REC) onto the closed foundation; idempotency explicit
4. Multi-signer fee-payer pool (removes the ≈ 5.33 mint/s single-signer write-lock bottleneck)
5. Then Rail B (DR, record-only), Dual-Tracker, and the designed 7-node consortium cluster

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

### Master Specification

| Doc | Covers |
| :--- | :--- |
| [`docs/master-architecture-v3.md`](docs/master-architecture-v3.md) | **Authoritative v3 spec.** Simulation scope, justification, settlement model, layered architecture, consensus topology, validation, build sequence, paper-integrity checklist. Supersedes all prior versions. |

### Blockchain Layer

| Doc | Covers |
| :--- | :--- |
| [`docs/blockchain-system.md`](docs/blockchain-system.md) | Full blockchain system overview — dual-layer model, smart contracts, token system, DR + P2P flows, governance |
| [`docs/blockchain-architecture.md`](docs/blockchain-architecture.md) | Service connection map, Thailand LA hierarchy, standards compliance, port reference |
| [`docs/blockchain-node-network.md`](docs/blockchain-node-network.md) | Consortium node network design — PoA cluster, node taxonomy, two-tier consensus, Chain Bridge gateway |

### Testing

| Doc | Covers |
| :--- | :--- |
| [`docs/testing/blockchain-integration-tests.md`](docs/testing/blockchain-integration-tests.md) | Chain Bridge, NATS pipeline, settlement, consortium node connectivity tests |

### General

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
