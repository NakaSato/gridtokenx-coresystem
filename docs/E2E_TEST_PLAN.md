# GridTokenX E2E Test Plan

> Status: draft · Last updated: 2026-06-06
> Scope: end-to-end test cases across all `gridtokenx-*` services + gateways + infra.

End-to-end = real services, real infra (Postgres/Redis/Kafka/NATS/Vault), real Solana validator (or Surfpool simnet). No mocks at boundaries. Each case asserts observable cross-service state, not just a 200.

## Legend

- `[ ]` not implemented · `[~]` partial / exists but flaky · `[x]` done
- **Pre** = preconditions · **Assert** = pass criteria · **Cleanup** = teardown

---

## 0. Harness & Preconditions

- [ ] Bring-up script: `./scripts/app.sh start` + `./scripts/app.sh init` (Solana + programs deployed)
- [ ] Health gate: `./scripts/app.sh doctor` green for all services before any case runs
- [ ] Seed reset between runs (truncate test schemas, flush Redis test keys, fresh Kafka topics or unique group ids)
- [ ] Deterministic test ids (timestamp/uuid suffix) — already pattern in `scripts/production-e2e.sh`
- [ ] Single test runner entrypoint: `just e2e` (new) wrapping per-suite scripts
- [ ] CI mode using `just simnet-ci` (Surfpool, no local validator) for blockchain cases
- [ ] Artifacts: capture logs per service on failure (`./scripts/app.sh logs <svc>`)

---

## 1. IAM Service (`:4010` REST / `:5010` gRPC)

Existing: `scripts/production-e2e.sh`, `scripts/test-registration-e2e.sh`.

- [~] **Register → verify → JWT issued** — `POST /api/v1/auth/register` then `GET /api/v1/auth/verify`. Assert `access_token` + `wallet_address` returned.
- [ ] **Login happy path** — valid creds → JWT + refresh token. Assert claims (role, sub, exp).
- [ ] **Login wrong password** — 401, no token, no user enumeration leak.
- [ ] **JWT refresh** — refresh token rotates, old refresh invalidated.
- [ ] **Wallet provisioning (Vault)** — on verify, AES-256-GCM key stored, `wallet_address` non-null, key retrievable via Vault Transit only. Assert no plaintext key in DB/logs.
- [ ] **On-chain user registration (custodial)** — onboard → Registry PDA created via Chain Bridge. Assert PDA exists on-chain (gRPC read), idempotent on re-onboard.
- [ ] **Link secondary wallet → auto on-chain** — `POST /api/v1/identity/...` links wallet, triggers on-chain. Assert mapping persisted + PDA updated.
- [ ] **KYC state transitions** — pending → verified → rejected. Assert downstream gating (unverified user blocked from trading).
- [ ] **RBAC enforcement** — prosumer vs admin endpoint access. Assert 403 on privilege escalation.
- [ ] **gRPC parity (`:5010`)** — auth introspection via ConnectRPC matches REST result.
- [ ] **Idempotent register** — duplicate email → 409, no orphan wallet/PDA.

## 2. Meter Registration (IAM ↔ Chain Bridge ↔ Anchor)

- [~] **Register meter → on-chain** — `POST /api/v1/meters`. Assert `meter.id`, meter PDA created (register_meter discriminator — recent fix `932a4e0`).
- [ ] **Meter bound to verified user only** — unverified owner rejected.
- [ ] **Duplicate meter id** — idempotent, no dup PDA.
- [ ] **Meter ↔ device identity (Ed25519)** — meter pubkey registered for later Oracle signature checks.

## 3. Oracle Bridge (`:4030` gRPC) + Telemetry Edge (Envoy `:4002`)

Existing: `tests/e2e/test_telemetry_security.py`.

- [~] **Valid signed reading accepted** — Edge sends Ed25519-signed reading via Envoy mTLS. Assert stored in InfluxDB.
- [ ] **Invalid signature rejected** — tampered payload / wrong key → reject, not stored, audit logged.
- [ ] **Unknown device rejected** — meter not in registry → reject.
- [ ] **Replay protection** — duplicate nonce/timestamp rejected.
- [ ] **15-min aggregation window** — N readings in window aggregate to one settlement-ready record. Assert window boundary correctness.
- [ ] **Dissemination fan-out** — verified reading published to Redis Streams + Kafka. Assert both consumers receive.
- [ ] **mTLS enforcement at Envoy** — non-mTLS client rejected at `:4002`.

## 4. Smartmeter Simulator (`:12010` API / `:12011` UI)

- [ ] **Simulator → Oracle ingestion** — `just send-meter-reading meter_id=METER-001 count=1` → reading lands in Oracle/InfluxDB.
- [ ] **Auto multi-meter stream** — `just auto-meter-send meters=5 interval=15` → 5 device streams aggregate correctly.
- [ ] **Simulator signs with registered key** — accepted; unregistered sim meter rejected (ties to §3).

## 5. Settlement & Minting (Oracle → Trading/Settlement → Chain Bridge → Anchor)

Reference: `docs/MINTING_E2E_FLOW.md`.

- [ ] **Telemetry → mint GRID/REC** — aggregated energy reading triggers settlement → mint tx via Chain Bridge → token minted on-chain. Assert on-chain balance increment matches kWh.
- [ ] **Message bus path** — settlement event flows NATS JetStream `chain.tx.submit`. Assert tx submitted, ack received.
- [ ] **Settlement idempotency** — same window not double-minted.
- [ ] **On-chain state verify** — final token account state queried via Chain Bridge gRPC matches expected.

## 6. Trading Service (`:8093` REST / `:8092` gRPC)

- [ ] **Place buy + sell order → match (CDA)** — crossing orders match. Assert trade created, both orders filled.
- [ ] **Partial fill** — partial qty match, remainder stays open.
- [ ] **No-cross resting order** — non-crossing order rests in book, no trade.
- [ ] **Cancel order** — open order cancelled, removed from book.
- [ ] **Order requires verified+funded user** — unverified or zero-balance rejected (ties IAM §1).
- [ ] **Settlement through Chain Bridge** — matched trade settles on-chain (token transfer). Assert balances move, no direct Solana RPC from Trading.
- [ ] **Order book consistency under concurrency** — N concurrent orders, no double-fill, invariant: sum fills ≤ order qty.
- [ ] **gRPC `:8092` parity** — matching via gRPC equals REST.

## 7. Chain Bridge (`:5040` gRPC)

- [ ] **Async tx submit (NATS)** — publish `chain.tx.submit` → tx signed (Vault Transit) + landed. Assert signature + slot.
- [ ] **Tx simulate** — `chain.tx.simulate` returns sim result without landing.
- [ ] **gRPC reads** — balance / account data / slot match on-chain truth.
- [ ] **Signing isolation** — binds `127.0.0.1` only; external connect refused. Vault Transit used (no local keypair in prod mode).
- [ ] **Tx failure surfaced** — failed/invalid tx returns structured error, no silent drop.

## 8. Noti Service (`:5050` gRPC)

- [ ] **Trade event → notification** — settled trade emits notification (RabbitMQ consume → dispatch). Assert delivered.
- [ ] **Registration/KYC event → notification** — onboarding triggers welcome/verify notice.
- [ ] **Dispatch retry** — transient failure retried, no duplicate on success.

## 9. Anchor Programs (`gridtokenx-anchor`)

- [ ] **Program tests pass** — `cd gridtokenx-anchor && anchor test` (Bankrun) green.
- [ ] **Registry: register_user / register_meter PDAs** — discriminators correct (recent fix), PDA derivation deterministic.
- [ ] **Token mint authority** — only Chain Bridge signer can mint. Unauthorized mint rejected.
- [ ] **Simnet run** — `just simnet-ci` deploys + core flows pass on Surfpool.

## 10. Explorer UI (`:11002`) + WASM (`gridtokenx-wasm`)

- [ ] **Explorer reads on-chain state** — after a settled trade/mint, explorer shows tx + balances.
- [ ] **WASM client builds + decodes** — wasm bindings decode account data correctly (unit/e2e in `gridtokenx-wasm`).

## 11. Gateways (APISIX `:4001`, Envoy `:4002`, API orchestrator `:4000`)

- [ ] **APISIX routing** — user-facing call via `:4001` reaches IAM/Trading, auth propagated.
- [ ] **Gateway secret enforcement** — `GATEWAY_SECRET` required (see existing scripts), missing → reject.
- [ ] **Envoy IoT path** — telemetry only via `:4002` mTLS (ties §3).
- [ ] **Health endpoints** — `:4000` health aggregates service status.

## 12. Cross-Platform Golden Path (the big one)

- [ ] **Full lifecycle**: register user → provision wallet → on-chain user PDA → register meter → meter PDA → simulator sends signed readings → Oracle validates + aggregates → settlement mints GRID → user places sell order → matches buyer → settles on-chain → balances transfer → notification dispatched → explorer reflects state.
  - **Assert** each hop's persisted/on-chain state. This is the regression anchor for the whole system.

---

## Suite Organization (proposed)

```
tests/e2e/
  00_harness/        # bring-up, health gate, seed reset
  10_iam/            # §1, §2
  20_oracle/         # §3, §4   (extend existing test_telemetry_security.py)
  30_settlement/     # §5
  40_trading/        # §6
  50_chain_bridge/   # §7
  60_noti/           # §8
  70_anchor/         # §9 (wraps anchor test / simnet)
  80_gateways/       # §11
  90_golden_path/    # §12
  run.sh             # orchestrates, called by `just e2e`
```

## Open Questions

- [ ] CI: local `solana-test-validator` vs Surfpool `simnet-ci` as default? (Apple Silicon ulimit caveat favors simnet in CI)
- [ ] Language: bash+curl+jq (existing) vs Python (existing telemetry test) vs Rust integration crate? Recommend: bash for HTTP flows, Python for gRPC/crypto, reuse existing.
- [ ] Test data isolation strategy: dedicated test schema vs ephemeral containers per run.
- [ ] Noti/Explorer assertions — need event-tap or polling helper; build shared assert lib.
