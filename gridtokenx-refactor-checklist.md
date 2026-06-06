# GridTokenX Refactor — Checklist & Test List

> Companion to [`gridtokenx-refactor-plan.md`](gridtokenx-refactor-plan.md) (the grounded plan + narrative log).
> This file = actionable checkboxes + per-slice test verification. Last updated: 2026-06-07.
>
> Legend: `[x]` done & verified · `[~]` deferred (intentional) · `[!]` blocked (missing infra) · `[ ]` open.

---

## Phase 1 — chain-bridge god-file split

- [x] **P1.1** `api.rs` (1667L) → `api/{provider,service}.rs` + `api/tests.rs`; `mod.rs` re-exports shared `use super::*`. *(commit `3eab5c4`)*
- [x] **P1.2** `nats_consumer.rs` (913L) → `nats_consumer/{mod,consumer,dedup,tests}.rs` (consumer 447L). *(commit `3eab5c4`)*

## Phase 2 — oracle-bridge single crate → 4-layer

- [x] **P2.1** workspace `crates/` = `oracle-{core,persistence,logic,protocol,api}`. *(already on `main`)*
- [x] **P2.3** extract `oracle-stacks` crate (dlms/sunspec/ocpp/openadr). *(already on `main`)*
- [x] **P2.4** AppState prune 13→9 fields (slice A).
- [~] **P2.4-deep** split AppState (9) → `IngressState` / `BlockchainState`. *(cosmetic, low value)*

## Phase 3 — blockchain-core de-fork (D1-A)

- [x] **P3** tag/version blockchain-core; delete `trading-service/crates/blockchain-core-compat`; repoint trading; verify build. *(commit `3eab5c4`)*
- [x] **D** trading-service `iam-protocol-compat` deleted; repointed to real `iam-protocol` path dep.

## Phase 4 — cross-cutting

- [x] **B** extract `gridtokenx-telemetry` shared crate (fmt-only, JSON default + `LOG_FORMAT=pretty`); path dep into all 5 services.
- [!] **C** NATS W3C `traceparent` propagation. *(blocked — needs OTLP spans + collector, none exist)*

## E — chain-bridge Reference-Monitor gaps

- [x] **E1** policy drift kill: delete orphan `chain-bridge-core::policy`; keep live `blockchain_core::PolicyEngine`. *(commit `edf7f29`)*
- [x] **E2** audit hash-chain wired into `sign_and_submit`; `AuditPort` + `with_audit`; Postgres/InMemory selection; `migrations/0001_audit_log.sql`. *(commit `edf7f29`)*
- [x] **E3** pre-sign simulation before Vault sign; tx-error → reject+audit `stage:"simulation"`, infra-error → advisory; opt-out `CHAIN_BRIDGE_PRESIGN_DISABLE`. *(commit `edf7f29`)*
- [x] **E4a** binary out of root → `crates/chain-bridge-api`; root → virtual manifest; lib/bin names + Dockerfile unchanged. *(commit `fd170e6`)*
- [~] **E4b** logic extraction (`chain-bridge-logic`: pull `sign_and_submit` out of connectrpc service) + de-fork (route live path through persistence `vault_signer`/`solana_client`, delete `vault.rs`/`api/provider.rs` forks, consume `litesvm_sim` + `chain-bridge-protocol`). *(touches Reference Monitor, purely structural — deferred)*

## Cross-cutting follow-ups (open)

- [ ] thread NATS envelope `correlation_id` into audit entries (currently `""`).
- [ ] apply `migrations/0001_audit_log.sql` to shared IAM DB (chain-bridge has no migration runner).
- [ ] `git add gridtokenx-telemetry/` in superproject (plain dir, not yet a submodule).
- [ ] commit `gridtokenx-refactor-plan.md` + this checklist in the superproject.
- [ ] optional: clippy sweep of chain-bridge root crate to pass `cargo clippy -- -D warnings` (many pre-existing warns: `field_reassign_with_default`, deref-refs).

---

## Test list

Run per service (`cd <service>` first — independent Cargo workspaces, never `cargo` from superproject root).

| Service | Command | Result (this session) |
| --- | --- | --- |
| chain-bridge | `cargo test` (from service root; virtual workspace → all members) | ✅ **97 passed / 12 ignored** (10 suites) |
| oracle-bridge | `cargo check` | ✅ 0 errors (slice A) — full `cargo test` not run this session |
| trading-service | `cargo check` | ✅ 0 errors (slice D) — full `cargo test` not run this session |
| iam-service | `cargo test` | not run this session |
| blockchain-core | `cargo test` | covered transitively by consumers; not run standalone this session |

### chain-bridge — key tests (must stay green)

- [x] `tests/invariants.rs` safety/liveness invariants (incl. `test_trading_service_can_submit_trading_tx` — fixed stale SPIFFE id → `.../trading-service/matcher`).
- [x] `api::tests` — gRPC handlers + signing path:
  - [x] `test_presign_simulation_rejects_before_signing` (E3, via `FailingSimProvider`).
  - [x] `test_sign_and_submit_empty_key_id_passes_unsigned`.
  - [x] existing submit/balance/account/simulate handler tests.
- [x] `nats_consumer::tests` — `claim_or_replay` dedup (Done replay / InFlight block / failure release), staleness, RBAC reject.
- [x] `chain-bridge-core` audit: `in_memory_chains_entries`, `second_entry_links_to_first` (hash-chain linkage).
- [x] `chain-bridge-persistence` adapter tests.

### Regression gates before any E4b / further crate work

- [ ] `cargo build --release --bin gridtokenx-chain-bridge` from service root succeeds (Dockerfile parity).
- [ ] `cargo test` from service root: 97 passed / 12 ignored (no regression).
- [ ] one signing path preserved — no second site touches Vault or submits a tx.
- [ ] `key_id == "platform_admin"` gate intact; identity from L4 (SPIFFE/mTLS), not L7.

### Not yet automated (manual / infra-dependent)

- [ ] audit hash-chain against real Postgres (only InMemory exercised in unit tests).
- [ ] pre-sign simulation against live RPC / Surfpool (mock-only in unit tests).
- [ ] NATS submit/simulate/cancel end-to-end (consumer handlers have no `async_nats::Message` test constructor).
- [ ] full integration suite: `just orb-up && just test-all`.
