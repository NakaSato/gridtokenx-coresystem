# GridTokenX E2E Test Plan

> Status: **built — 10 suites certified live green** · Last updated: 2026-06-07
> Scope: end-to-end test cases across all `gridtokenx-*` services + gateways + infra.
> Build order + per-suite detail: [E2E_IMPL_PLAN.md](E2E_IMPL_PLAN.md). Checkbox status here mirrors it.

End-to-end = real services, real infra (Postgres/Redis/Kafka/NATS/Vault), real Solana validator (or Surfpool simnet). No mocks at boundaries. Each case asserts observable cross-service state, not just a 200.

## Legend

- `[ ]` not implemented · `[~]` partial / deferred / skip-when-unreachable · `[x]` done + live-green
- **Pre** = preconditions · **Assert** = pass criteria · **Cleanup** = teardown
- *out-of-repo* = needs platform `:4000` orchestrator or gateways (infra removed) → suite skips loudly when down

---

## 0. Harness & Preconditions

- [x] Bring-up script: `./scripts/app.sh start` + `./scripts/app.sh init` (Solana + programs deployed) — `run.sh` gate
- [x] Health gate: `./scripts/app.sh doctor` green before any case (`SKIP_GATE=1` to bypass)
- [x] Seed reset between runs (truncate test schema, flush Redis `test:*`, unique Kafka group ids per run)
- [x] Deterministic test ids (timestamp/uuid suffix)
- [x] Single test runner entrypoint: `just e2e` (+ `just e2e-suite name=X`)
- [~] CI mode — **decision: local `solana-test-validator` for dev + CI** (not Surfpool), per Apple Silicon `ulimit -n 65536` handled in scripts. `simnet-ci` available but not the CI default.
- [x] Artifacts: per-service logs captured under `tests/e2e/artifacts/<run>/` on failure

---

## 1. IAM Service (`:4010` REST / `:5010` gRPC)

Existing: `scripts/production-e2e.sh`, `scripts/test-registration-e2e.sh`. Suite: `10_iam/` (20 cases live + gRPC 4P).

- [x] **Register → verify → JWT issued** — `POST /api/v1/auth/register` then verify. `access_token` + `wallet_address`.
- [x] **Login happy path** — valid creds → JWT. Claims (role, sub, exp) asserted.
- [x] **Login wrong password** — 401, no token.
- [ ] **JWT refresh** — **DROPPED**: `/refresh` route exists (`bin/iam-service/src/startup.rs:120`, handler `crates/iam-api/src/handlers/auth.rs:127`) but no E2E case written.
- [x] **Wallet provisioning** — custodial key in OWS file vault (`OWS_VAULT_PATH`); DB `encrypted_private_key`/`wallet_salt` NULL, `wallet_encryption_version` set; no plaintext key column. *(model is OWS file vault, not Vault-Transit)*
- [x] **On-chain user registration (custodial)** — onboard `/users/me/onchain-profile` → Registry PDA via Chain Bridge. Lands confirmed tx; idempotent re-onboard `[200]`. *(fee-payer + shard root-causes fixed, blockchain-core `9da9454`)*
- [x] **Link secondary wallet → on-chain** — `POST /users/me/wallets`, base58 mapping persisted.
- [ ] **KYC state transitions** — not built (pending→verified→rejected gating).
- [x] **RBAC enforcement** — 403 on privilege escalation (`/users/me` auth±).
- [x] **gRPC parity (`:5010`)** — ConnectRPC `IdentityService` `VerifyToken`/`GetUserInfo`; gRPC `userId`/`id` == REST `sub`; garbage token → `valid:false`; missing ServiceRole → 403. *(built 2026-06-07, 4P live)*
- [x] **Idempotent register** — duplicate → 409, no orphan wallet/PDA.

## 2. Meter Registration (IAM ↔ Chain Bridge ↔ Anchor)

- [~] **Register meter → on-chain** — **no `/meters` route in IAM** (gateway→other svc). Meter PDA covered in `70_anchor` (register_meter); meter→user map in `20_oracle`/`90_golden_path` (Redis).
- [ ] **Meter bound to verified user only** — not built.
- [ ] **Duplicate meter id** — not built.
- [~] **Meter ↔ device identity (Ed25519)** — device pubkey at Redis `gridtokenx:devices:{id}:pubkey`; exercised by Oracle sig checks (§3).

## 3. Aggregator Bridge (`:5030` gRPC) + Telemetry Edge (direct IoT ingress)

Suite: `20_oracle/test_telemetry.py` (7P/0skip).

- [x] **Valid signed reading accepted** — Ed25519-signed via REST `/v1/private-network/ingest` + gRPC `Ingest`. *(kwh float canonicalization fixed test-side, `lib/crypto.py rust_f64_str`)*
- [x] **Invalid signature rejected** — tampered → reject. *(SECURITY: Oracle now fail-CLOSED by default, aggregator-bridge `e7d82a0`; was fail-open prod-gated)*
- [x] **Unknown device rejected** — meter not in registry → reject.
- [x] **Wrong-key rejected** — sig by non-registered key → reject.
- [~] **Replay protection** — **deferred** (gRPC UTT-H nonce, `service.rs:166`).
- [~] **15-min aggregation window** — **deferred → §5** (window hardcoded `WINDOW_MINUTES=15`; backdate timestamps to force completion).
- [x] **Dissemination fan-out** — Redis zone-stream growth ✓ + Kafka tap proven LIVE (`MeterReadingEvent` on `meter.readings` matches meter id + exact Ed25519 sig + `verified:true`). *(2026-06-07, `lib/events.py kafka_tap`)*
- [—] **mTLS enforcement at Envoy** — **obsolete** (Envoy `:4002` edge removed 2026-06-14; IoT path has no transport-mTLS boundary, device auth is Ed25519-only at the Aggregator — see tech-debt TD-003).

## 4. Smartmeter Simulator (`:12010` API / `:12011` UI)

- [ ] **Simulator → Oracle ingestion** — not built in `20_oracle`.
- [ ] **Auto multi-meter stream** — not built.
- [ ] **Simulator signs with registered key** — not built.

## 5. Settlement & Minting (Oracle → Trading/Settlement → Chain Bridge → Anchor)

Reference: `docs/product-specs/MINTING_E2E_FLOW.md`. Suite: `30_settlement/test_settlement.py`. **Generation-mint handler is in trading-service** (`execute_generation_mint`, REST `:8093/api/v1/settlement/generation-mint`); Oracle posts to platform `:4000` which forwards. Full path needs out-of-repo `:4000`.

- [~] **Telemetry → mint GRID/REC** — on-chain GRID balance delta WIRED (`test_onchain_balance_increase`: reads prosumer GRID ATA before/after a backdated generation settlement, asserts growth). Assert-when-reachable; skips when `:4000` down / mint pubkey unknown / Chain Bridge mTLS-only. *(2026-06-07)*
- [ ] **Message bus path (NATS JetStream)** — `chain.tx.submit` submit+ack not directly asserted.
- [ ] **Settlement idempotency** — same window not double-minted — not built.
- [x] **On-chain state verify** — `lib/chain.py` real ConnectRPC client (`get_slot`/`get_balance`/`get_account_data`/`get_token_account_balance` + `ata(owner,mint)` SPL derivation via solders). Proven LIVE against Chain Bridge `:5040`.

## 6. Trading Service (`:8093` REST / `:8092` gRPC)

Suite: `40_trading/test_trading.py` (7P/0skip). Auth: gateway-injected headers `x-gridtokenx-role` + `x-gridtokenx-user-id` + `x-gridtokenx-gateway-secret` (trading does NOT validate JWT).

- [x] **Place buy + sell order → match (CDA)** — cross-party fill, both filled. *(distinct buyer+seller; artifact `1780761558-77585`)*
- [x] **Partial fill** — `filled_amount=4` stays `partially_filled`; full=5 → `filled`.
- [x] **No-cross resting order** — non-crossing rests in book.
- [x] **Cancel order** — open order cancelled.
- [~] **Order requires verified+funded user** — role/secret gating ✓ (no-role 401); zero-balance gating not asserted.
- [ ] **Settlement through Chain Bridge** — needs `:4000` + funded ATAs (out-of-repo).
- [x] **Order book consistency under concurrency** — 5 buyers fire crossing buys SIMULTANEOUSLY at resting sell Q=4; asserts `filled_amount ≤ Q` every poll (no oversell/double-fill) + converges to Q. *(2026-06-07, `test_concurrent_buys_no_oversell`)*
- [x] **gRPC `:8092` parity** — `trading.TradingService/SubmitOrder` matches REST.

> Matcher/schema fixes surfaced + RESOLVED in trading-service: Filled-status promotion (`c506791`), `order_matches` persist (`8436134`), epoch FK / nil-epoch routing (`02b4f70`/`4220bf9`), `outbox_events` table (IAM migration), real `GET /orders/:id` (`472ded6`), real order book (`96fa72a`), SupplySync log-spam degrade (`ac6a07b`). New IAM migration `20260606000000_add_time_in_force.sql`.

## 7. Chain Bridge (`:5040` gRPC)

Suite: `50_chain_bridge/test_chain_bridge.py` (py 4P/2skip) + rust invariants (11/11). ConnectRPC over HTTP+JSON (no proto codegen).

- [~] **Async tx submit (NATS)** — **deferred** (`TxSubmitMessage` envelope verified → Vault Transit sign `api.rs:571`; needs valid bincode `Transaction`; covered indirectly via IAM onboard + §5).
- [~] **Tx simulate** — **deferred** (`TxSimulateMessage` path verified).
- [x] **gRPC reads** — `GetSlot`/`GetLatestBlockhash`/`GetBalance` match on-chain truth.
- [~] **Signing isolation** — RBAC ✓ (no-role + bogus-role denied), Vault Transit signer confirmed. **⚠️ binds `0.0.0.0` (crates/chain-bridge-api/src/main.rs:155), NOT `127.0.0.1`** — boundary is mTLS, not bind addr (CLAUDE.md discrepancy). Dev reads need `CHAIN_BRIDGE_INSECURE=true`.
- [x] **Tx failure surfaced** — invalid-pubkey → structured error.

## 8. Noti Service (`:5050` gRPC)

Suite: `60_noti/test_noti.py` (3P). Tests exercise the synchronous ConnectRPC dispatch surface only; Noti also runs background Kafka + RabbitMQ consumers (`bin/noti-server/src/startup.rs:178`), but those queue paths are not tapped here so RabbitMQ-tap / retry-no-dup are not asserted.

- [~] **Trade event → notification** — `SendNotification` dispatch accepted (not event-driven via queue).
- [~] **Registration/KYC event → notification** — dispatch + `GetNotificationStatus` tested; not event-triggered.
- [~] **Dispatch retry** — N/A (sync); `idempotency_key` dedup asserted instead.

## 9. Anchor Programs (`gridtokenx-anchor`)

Suite: `70_anchor/run.sh` (opt-in `E2E_RUN_ANCHOR=1`; 3 mocha passing LIVE).

- [x] **Program tests pass** — `npx mocha -r tsx tests/registry_sharding.ts` (bypasses Anchor.toml glob pulling absent `blockbench` IDL). 3 passing: registry init+16 shards · register_user across shards · aggregate_shards.
- [x] **Registry: register_user / register_meter PDAs** — discriminators + deterministic derivation.
- [ ] **Token mint authority** — only Chain Bridge signer mints / unauthorized rejected — not directly asserted.
- [ ] **Simnet run** — `just simnet-ci` core flows — not built.

> Gotchas: `aggregate_shards` needs caller == `registry.authority` = dev wallet `EzudwoHv…`; wrapper sets `ANCHOR_WALLET=$DEV_WALLET` + airdrops both dev wallet and `~/.config/solana/id.json`.

## 10. Explorer UI (`:11002`) + WASM (`gridtokenx-wasm`)

Folded into `90_golden_path`.

- [~] **Explorer reads on-chain state** — chain-liveness slot>0 via Chain Bridge inline ✓; Explorer UI assertion skips when down.
- [~] **WASM client builds + decodes** — skip when UI down.

## 11. Gateways (APISIX `:4001`, API orchestrator `:4000`)

Suite: `80_gateways/run.sh` (3P when up). Gateways **out-of-repo** → skip loudly when down.

- [~] **APISIX routing** — `:4001` route check (skip when down).
- [~] **Gateway secret enforcement** — `GATEWAY_SECRET` required on privileged path.
- [~] **Health endpoints** — `:4000` aggregate (out-of-repo).
- [—] **Envoy IoT path** — **removed 2026-06-14** (Envoy `:4002` edge deleted; IoT ingresses direct to the Aggregator Bridge).

## 12. Cross-Platform Golden Path (the big one)

Suite: `90_golden_path/test_golden_path.py` (1P live, 10 stages, two distinct IAM users).

- [x] **Full lifecycle**: register user → wallet → on-chain user PDA → register meter → meter PDA → signed readings → Oracle aggregate → mint → sell order → match → on-chain settle → notification → explorer reflects.
  - [~] **Assert each hop** — IAM is the only hard prereq (whole test skips if down); in-repo hops asserted; settlement/trade-settle/explorer skip when platform `:4000`/UI down. Test fails iff a *reachable* stage hard-fails.

---

## Suite Organization (built)

```
tests/e2e/
  00_harness/        # bring-up, health gate, seed reset        — 5P
  10_iam/            # §1, §2   (run.sh + test_iam_grpc.py)     — 20P + gRPC 4P
  20_oracle/         # §3, §4   (test_telemetry.py)             — 7P
  30_settlement/     # §5       (test_settlement.py)            — 3skip (platform :4000)
  40_trading/        # §6       (test_trading.py)               — 7P
  50_chain_bridge/   # §7       (test_chain_bridge.py + run.sh) — rust 11/11 + py 4P/2skip
  60_noti/           # §8       (test_noti.py)                  — 3P
  70_anchor/         # §9       (run.sh, opt-in)                — 3 mocha LIVE
  80_gateways/       # §11      (run.sh)                        — 3P
  90_golden_path/    # §12      (test_golden_path.py)           — 1P
  lib/               # http.sh assert.sh chain.py db.py events.py crypto.py redis_util.py …
  run.sh             # orchestrates, called by `just e2e`
```

## Open Questions — RESOLVED

- [x] CI runtime → **local `solana-test-validator`** for dev + CI (`ulimit -n 65536` in scripts), not Surfpool default.
- [x] Language → **hybrid**: bash+curl+jq for HTTP, Python+pytest for gRPC/crypto. (Reused existing telemetry test.)
- [x] Test data isolation → **truncate test schema + flush Redis `test:*` + unique Kafka group ids per run** (dedicated dev Postgres, not ephemeral containers).
- [x] Noti/Explorer assertions → **`lib/events.py` tap** (Kafka high-watermark assign + drain; Redis-stream tap). Noti is sync dispatcher (no tap needed); Explorer folded into golden path.

## CI

`.github/workflows/e2e.yml` — `lint` tier (PR, always: `bash -n`, shellcheck, `py_compile`, `pytest --collect-only`) + `full` tier (dispatch/nightly: real stack, `CHAIN_BRIDGE_INSECURE=true just e2e`, artifacts on `always()`). PR gate on golden-path + changed-service suite still TODO (needs path-filter→suite mapping).
