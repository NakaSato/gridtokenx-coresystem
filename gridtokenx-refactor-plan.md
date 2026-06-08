# GridTokenX Refactor Plan (grounded)

> Corrects `gridtokenx-rust-structure.md` against actual repo state (verified 2026-06-07).
> Target architecture from that doc is sound; its "current state" claims were largely stale/wrong.
> Checkbox/test view: [`gridtokenx-refactor-checklist.md`](gridtokenx-refactor-checklist.md).

## Status (2026-06-07)

**Plan substantively complete.** All phases landed; only intentional deferrals + one blocked item remain.

- ✅ Done: P1.1, P1.2 (god-files) · P2 (oracle 6-crate, pre-existing) · P3/D (de-fork) · B (telemetry) · E1/E2/E3 (policy/audit/pre-sign) · E4a (binary → `crates/chain-bridge-api`, root virtual manifest).
- ⏳ Deferred (structural, no behavior gain): E4b (logic extraction + persistence de-fork) · P2.4-deep (AppState IngressState/BlockchainState).
- ⛔ Blocked: C (NATS traceparent — needs OTLP + collector).
- chain-bridge commits: `c92a45a` (god-file split) → `edf7f29` (E1-E3) → `fd170e6` (E4a). Tests: 97 passed / 12 ignored from service root.

## Reality vs doc

| Service | Doc says | Actual |
|---|---|---|
| iam, noti | done | ✅ done (4-layer) |
| trading-service | refactor target | ✅ already done — `trading-engine` + `trading-{core,persistence,logic,api,protocol,infra}` + compat shims |
| aggregator-bridge | refactor target | ✅ **DONE** — 6-crate workspace `oracle-{core,persistence,logic,protocol,api}` + `oracle-stacks` (the "single crate, 555L" claim was stale at writing; split already on `main`). |
| chain-bridge | flat `rpc::{account,...}` | ✅ **DONE** — multi-crate workspace (root = virtual manifest); binary+lib in `crates/chain-bridge-api` (god-files split into `api/` + `nats_consumer/`); ports in `chain-bridge-core`, adapters in `chain-bridge-persistence`. edition 2024. |
| blockchain-core | thin types kernel | ❌ fat behavior lib (auth/config/rpc/wallet/policy/instructions); consumed by all 5 services; trading **forked** it into `blockchain-core-compat` = real drift |

Debunked doc claims: no `shard_for` fn anywhere (anti-pattern #4 fabricated); §5 version template wrong (solana 1.18 vs real 2.x, axum 0.7 vs 0.8.7, connectrpc 0.4 vs 0.2.1, buffa 0.4 vs 0.2.0).

## Phase 0 — Decisions
- **D1 blockchain-core:** A=keep fat, kill fork (version it, delete compat, repoint trading). **Chosen: A.** B=split thin → defer to Tier 2.
- **D2 chain-bridge:** incremental — split god-files into modules first; crate split (core/persistence/logic/api) only when 3 gaps work lands. **Chosen: incremental.**

## Phase 1 — chain-bridge (god-file split) ✅ DONE
1. `api.rs` (1667L) → `api/{routes,handlers,sim,balance,tx_submit,...}.rs` by concern. Mechanical, no behavior change.
2. `nats_consumer.rs` (913L) → `nats/{consumer,handlers,schema}.rs`.
3. (If gaps wanted) introduce `crates/` core/persistence/logic/api; traits→core, vault+solana+nats impls→persistence.
4. Gaps incrementally: policy engine, audit hash-chain, LiteSVM pre-sign sim (partial sim already at `api.rs:284`).
- ⚠️ edition 2024 — keep.

## Phase 2 — aggregator-bridge (single → 4-layer) ✅ DONE (2.4-deep deferred)
1. Workspace `crates/`: oracle-{core,persistence,logic,protocol,api}.
2. Move: models+traits→core; `infra/`(kafka,rabbitmq,crypto,meter_registry)→persistence; `ingester/`+`dispatch/`+`aggregator`→logic; `grpc/`→protocol+api; handlers/router/main→api.
3. Extract `oracle-stacks` crate from `protocol/stacks/` (dlms/sunspec/ocpp/openadr).
4. Shrink AppState (13 fields) → IngressState / BlockchainState.

## Phase 3 — blockchain-core de-fork (D1-A) ✅ DONE
1. Tag/version blockchain-core.
2. Delete `trading-service/crates/blockchain-core-compat`; repoint trading imports.
3. Verify trading builds on real crate.

## Phase 4 — cross-cutting
- Extract `gridtokenx-telemetry` shared crate (lift oracle `telemetry::init_telemetry`).
- NATS W3C `traceparent` propagation (real gap).

## Skip / defer
- ❌ trading-matching extract — done (`trading-engine`).
- ❌ §5 version template — wrong versions; lift real versions from iam instead.
- ⏸ thin-kernel split, Citus, SPIFFE, Merkle anchor — Tier 2+.

## Order
Phase 1 → 3 (cheap drift kill) → 2 → 4. Verify `cargo check && cargo test` green per step.

---

## Execution log

| Slice | What | Status |
|---|---|---|
| P1.1 | chain-bridge `api.rs` (1667L) god-file split → `api/{provider,service}.rs` + `api/tests.rs`. `provider.rs` = `SolanaProvider` trait + Real/Surfpool impls + `BlockhashCache`; `service.rs` = `ChainBridgeGrpcService` (gRPC handlers + `extract_role` + `sign_and_submit`). `mod.rs` re-exports shared `use super::*` imports. Mechanical, no behavior change. Landed in commit `3eab5c4`. | ✅ 2026-06-07 |
| P1.2 | chain-bridge `nats_consumer.rs` (913L) god-file split → `nats_consumer/{mod,consumer,dedup,tests}.rs`. `consumer.rs` (447L) = `NatsConsumer` subscribe loop + `handle_{submit,simulate,cancel}` + `claim_or_replay`; `dedup.rs` = `DedupRecord`/`DedupState`; `mod.rs` = struct + shared imports. Mechanical, no behavior change. Landed in commit `3eab5c4`. | ✅ 2026-06-07 |
| P2 | aggregator-bridge single crate → 6-crate workspace `oracle-{core,persistence,logic,protocol,api}` + bonus `oracle-stacks` (plan 2.3 dlms/sunspec/ocpp/openadr). `src/` = `main.rs` only; `oracle-api` re-exports logic/persistence/protocol/stacks/core. **Already committed to `main`** (predates this plan — plan's "single crate, biggest 555L" reality was stale at writing; that 555L file is now `oracle-api/src/ingester/zone_ingester.rs`). AppState prune (2.4) = slice A (13→9). Deeper IngressState/BlockchainState split = not done, optional polish. | ✅ pre-existing |
| A | aggregator-bridge AppState prune: removed ocpp/sunspec/openadr_stack + settlement_signer dead fields (13→9 fields). `cargo check` 0 errors. | ✅ 2026-06-07 |
| D | trading-service iam-protocol-compat deleted; repointed to real `iam-protocol` cross-workspace path dep. `cargo check` 0 errors. | ✅ 2026-06-07 |
| B | gridtokenx-telemetry shared crate (fmt-only, JSON default + `LOG_FORMAT=pretty`). New sibling crate; path dep into all 5 services; per-service `telemetry` modules → thin re-export shims; chain-bridge `fmt::init()` → `gridtokenx_telemetry::init`. All 5 `cargo check` 0 errors. | ✅ 2026-06-07 |
| C | NATS W3C traceparent propagation | ⏸ deferred — needs OTLP spans + collector (none exist). Revisit with E or Tier 2. |
| E1 | chain-bridge policy drift kill (Direction X): deleted orphan `chain-bridge-core::policy` (declarative dup w/ no fact-extractor); kept proven live `blockchain_core::PolicyEngine`. `cargo check` + test-compile 0 errors. Also restored linter-stripped test-only import in `middleware.rs`. | ✅ 2026-06-07 |
| E2 | audit hash-chain wired into live `sign_and_submit`. Root binary now depends on `chain-bridge-{core,persistence}` (de-orphaned). `ChainBridgeGrpcService` gained defaulted `audit: Arc<dyn AuditPort>` + `with_audit` builder (signatures stable). Records Rejected{policy/auth/submit} + Submitted at the single signing chokepoint (covers gRPC + NATS, both funnel through it). main selects PostgresAuditStore (DATABASE_URL) else InMemory. Migration `migrations/0001_audit_log.sql` (apply via shared IAM DB — chain-bridge has no runner). Best-effort append (logs, never gates the effect). +2 tests. 85 passed/6 ignored, 0 clippy errors. | ✅ 2026-06-07 |
| E3 | pre-sign simulation wired into live `sign_and_submit`. Inside the `platform_admin` branch, after blockhash set and **before** Vault signs, `self.provider.simulate_transaction(&tx)` runs (tx still unsigned; provider sim defaults `sig_verify=false`). Definitive tx-level sim error → reject + audit `Rejected{stage:"simulation"}` (saves a Vault op on a doomed tx). RPC/infra sim error → advisory (warn, proceed) so a sim outage can't halt all writes. Opt out via `CHAIN_BRIDGE_PRESIGN_DISABLE=true`. Note: live `api::SolanaProvider` already simulates, so the orphan `persistence/litesvm_sim.rs` (`PreSignSimulatorPort` over the *forked* persistence providers) was **not** used by the live path — left for the E4 crate split. +1 test (`test_presign_simulation_rejects_before_signing` via `FailingSimProvider`). Also fixed 2 pre-existing persistence clippy warns (collapsible_if, len-without-is_empty). 86 passed/6 ignored. | ✅ 2026-06-07 |
| E4a | chain-bridge binary moved out of root → `crates/chain-bridge-api` (lib `gridtokenx_chain_bridge` + bin `gridtokenx-chain-bridge`, names unchanged). Root `Cargo.toml` → **virtual manifest** (no package, `members=["crates/*"]`, `[profile.release]` kept). `src/`, `tests/`, `build.rs` → `git mv` into the api crate (tracked as renames, no behavior change); build.rs proto path `../` → `../../../`; path deps `../` → `../../../` (telemetry, blockchain-core). Dockerfile unchanged (still `cargo build --bin gridtokenx-chain-bridge` from root, same target path). CLAUDE.md workspace/module map updated. `cargo test` from root now runs ALL members: 97 passed/12 ignored. | ✅ 2026-06-07 |
| E4b | **deferred** — logic extraction (`chain-bridge-logic`: pull `sign_and_submit` pipeline out of the connectrpc `ChainBridgeGrpcService`) + de-fork (route live path through persistence `vault_signer`/`solana_client` adapters, delete `src/vault.rs`+`api/provider.rs` forks, consume `litesvm_sim`/`chain-bridge-protocol`). Both touch the Reference Monitor; purely structural, no behavior/security gain. | ⏳ deferred |

### Pre-existing issue found (not caused by refactor) — ✅ RESOLVED
- `gridtokenx-chain-bridge/tests/invariants.rs::test_trading_service_can_submit_trading_tx` was FAILING: used bare SPIFFE id `…/prod/trading-service`, but hardened `ServiceRole::From` table only maps `…/trading-service/{api,matcher}` → bare form resolved to `Unknown` → policy denied → `is_ok()` assert failed. **Fixed** (committed `edf7f29`): id → `…/trading-service/matcher` (matches sibling blockchain_core test). Now green.
