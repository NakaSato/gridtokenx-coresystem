# GridTokenX Refactor Plan (grounded)

> Corrects `gridtokenx-rust-structure.md` against actual repo state (verified 2026-06-07).
> Target architecture from that doc is sound; its "current state" claims were largely stale/wrong.

## Reality vs doc

| Service | Doc says | Actual |
|---|---|---|
| iam, noti | done | ✅ done (4-layer) |
| trading-service | refactor target | ✅ already done — `trading-engine` + `trading-{core,persistence,logic,api,protocol,infra}` + compat shims |
| oracle-bridge | refactor target | ✅ true — single crate, flat modules, biggest file 555L |
| chain-bridge | flat `rpc::{account,...}` | ❌ wrong modules. Real = single crate (edition 2024); `api.rs` 1667L god-file + `nats_consumer.rs` 913L |
| blockchain-core | thin types kernel | ❌ fat behavior lib (auth/config/rpc/wallet/policy/instructions); consumed by all 5 services; trading **forked** it into `blockchain-core-compat` = real drift |

Debunked doc claims: no `shard_for` fn anywhere (anti-pattern #4 fabricated); §5 version template wrong (solana 1.18 vs real 2.x, axum 0.7 vs 0.8.7, connectrpc 0.4 vs 0.2.1, buffa 0.4 vs 0.2.0).

## Phase 0 — Decisions
- **D1 blockchain-core:** A=keep fat, kill fork (version it, delete compat, repoint trading). **Chosen: A.** B=split thin → defer to Tier 2.
- **D2 chain-bridge:** incremental — split god-files into modules first; crate split (core/persistence/logic/api) only when 3 gaps work lands. **Chosen: incremental.**

## Phase 1 — chain-bridge (god-file split)
1. `api.rs` (1667L) → `api/{routes,handlers,sim,balance,tx_submit,...}.rs` by concern. Mechanical, no behavior change.
2. `nats_consumer.rs` (913L) → `nats/{consumer,handlers,schema}.rs`.
3. (If gaps wanted) introduce `crates/` core/persistence/logic/api; traits→core, vault+solana+nats impls→persistence.
4. Gaps incrementally: policy engine, audit hash-chain, LiteSVM pre-sign sim (partial sim already at `api.rs:284`).
- ⚠️ edition 2024 — keep.

## Phase 2 — oracle-bridge (single → 4-layer)
1. Workspace `crates/`: oracle-{core,persistence,logic,protocol,api}.
2. Move: models+traits→core; `infra/`(kafka,rabbitmq,crypto,meter_registry)→persistence; `ingester/`+`dispatch/`+`aggregator`→logic; `grpc/`→protocol+api; handlers/router/main→api.
3. Extract `oracle-stacks` crate from `protocol/stacks/` (dlms/sunspec/ocpp/openadr).
4. Shrink AppState (13 fields) → IngressState / BlockchainState.

## Phase 3 — blockchain-core de-fork (D1-A)
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
