# Plan — Harden meter→solana settlement path

> Scope: the verified end-to-end flow
> `smartmeter → aggregator-bridge → blockchain-core → chain-bridge → solana`.
> Two gaps found during trace (2026-06-13); this plan closes them and documents the path.

## Findings (from trace)

- [ ] **G1 — NATS envelope-sig enforcement OFF by default.** Aggregator signs the
  `chain.tx.submit` envelope (`gridtokenx-blockchain-core/src/rpc/nats_provider.rs:127`),
  but chain-bridge only logs on unsigned/invalid unless `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true`
  (`chain-bridge/.../nats_consumer/auth.rs:168-177`). Prod can accept forged envelopes.
- [ ] **G2 — Path silently degrades.** Real tx path needs BOTH `MINT_VIA_CHAIN_BRIDGE=true`
  AND `NATS_URL` set. Missing either → falls to gRPC or HTTP-settle-to-trading-service
  (`aggregator-bridge/.../settlement_engine.rs:373`) with no loud signal.
- [ ] **G3 — InfluxDB doc drift.** Docs/CLAUDE.md claim InfluxDB time-series; code uses
  Kafka + Redis Streams only. No influx client in tree.

## Tasks

### Phase 1 — Enforce signed NATS (G1)
- [x] Confirm prod default of `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS` in deploy manifests
      (docker-compose / k8s / `.env.example`). — only docker-compose + `.env.example` in tree (no k8s); both `${...:-false}`.
- [x] Flip default to `true` for non-dev profiles; keep dev escape hatch explicit.
      — local-dev default kept `false` (no client certs in dev; hardcoding true breaks dev);
      non-dev=true now an explicit documented contract in `.env.example:106` + `docker-compose.yml:544`.
- [x] Verify aggregator always loads envelope signer when publishing (mTLS PEM present):
      `blockchain-core/src/rpc.rs:222-226`. Already fail-fast: mTLS-PEM branch `?`-propagates a
      signer-build error; insecure branch keeps warn-and-unsigned dev fallback.
- [x] Audit-log every rejected envelope into the hash-chain — already wired: enforcement path
      records via `audit_rejection(...,"auth",reason)` (`nats_consumer/consumer.rs:290-292`).

### Phase 2 — Loud degradation (G2)
- [x] At aggregator startup, log WARN (or refuse) if `MINT_VIA_CHAIN_BRIDGE=true` but
      `NATS_URL` unset → would silently use gRPC/HTTP fallback. — `src/main.rs` after path resolve.
- [x] Emit a metric `settlement_path{path="nats|grpc|http"}` so the active path is observable.
      — `::metrics::gauge!("settlement_path","path"=>...).set(1.0)` after recorder init.
- [x] Document the 3 settlement paths + their env gates in
      `gridtokenx-aggregator-bridge/ARCHITECTURE.md`. — new "Settlement path selection" table.

### Phase 3 — Doc fixes (G3)
- [x] Remove/replace InfluxDB claim in superproject `CLAUDE.md` "Aggregator Bridge" gotcha.
- [x] Add e2e trace table (this doc's path map) to `ARCHITECTURE.md` §8 index. — new §8.1.
- [x] Run `just lint-docs` — fix any stale `path:line` citations. — `lint-docs-all` clean (12 repos).

### Phase 4 — End-to-end verification ✅ PASSED 2026-06-13 (62s)
- [x] Bring up infra — settlement stack already UP in Docker (aggregator-bridge,
      chain-bridge, NATS :9020, Vault :13001, Redis, IAM, trading; validator :8899).
      (`app.sh status` mislabels them "Stopped" — it checks native PIDs, not containers.)
- [x] Seed meter pubkeys — `30_settlement/test_path_b_generation_mint.py` self-registers
      the device Ed25519 key + meter→user mapping in Redis.
- [x] Confirm GRID mint lands for one 15-min window — **PASS**, exact on-chain delta
      `50 kWh × 1e9` on the user's GRID ATA. Ran:
      `E2E_MINT_VIA_CHAIN_BRIDGE=1 GRIDTOKENX_API_KEY=e2e-test-key CHAIN_BRIDGE_INSECURE=true
       ENERGY_TOKEN_MINT=GktSLt9d… .venv/bin/python -m pytest 30_settlement/test_path_b_generation_mint.py`.

Two env fixes were needed (NOT product bugs):
- Test omitted the `X-API-KEY` header that `/v1/private-network/ingest` requires
  (`api_key_auth`) → 401 at ingest. Added env-driven header (`GRIDTOKENX_API_KEY`,
  default `e2e-test-key`) to the test.
- The container's static key `e2e-test-key` was not registered in IAM (reachable IAM
  → no static fallback). Provisioned an IAM `api_keys` row with the correct
  `SHA256(key + API_KEY_SECRET)` hash so `VerifyApiKey` returns valid.
Pre-run Redis hygiene (memory): `DEL gridtokenx:settlement:bins` + `XGROUP SETID
gridtokenx:events:zone_{0..9} aggregator_bridge_zone_group $` to clear simulator backlog.

## Test list

### Unit
- [ ] `auth.rs` — valid envelope (cert→CA→SPIFFE→P256 sig) → `Authenticated`.
- [ ] `auth.rs` — tampered tx bytes (tx_sha256 mismatch) → reject.
- [ ] `auth.rs` — SPIFFE SAN ≠ `service_identity` → reject.
- [ ] `auth.rs` — cert not signed by `CHAIN_BRIDGE_TLS_CA` → reject.
- [ ] `auth.rs` — `require_signed=true` + unsigned envelope → reject (not log-only).
- [ ] `auth.rs` — `require_signed=false` + unsigned → log-only, proceed (dev parity).
- [ ] `envelope_auth.rs` — canonical bytes stable across field reorder (domain-tag + length-prefix).
- [ ] aggregator `crypto.rs` — Ed25519 device sig: valid / wrong-key / bad-len(≠64) / Redis-down(fail-closed).
- [ ] aggregator `handlers.rs` — 3 sig fallbacks (canonical / sec-scale ts / JSON).
- [ ] `aggregator.rs` — window floor + bin accumulate + `peek_completed_bins` boundary (`end_time <= now`).
- [ ] chain-bridge `consumer.rs` — `claim_or_replay`: InFlight blocks dup, Done replays, failure releases.
- [ ] chain-bridge `service.rs` — `key_id != "platform_admin"` rejected; empty allowed.
- [ ] chain-bridge `service.rs` — blockhash served from cache; RPC fallback only when empty.

### Integration (`tests/invariants.rs` + aggregator tests)
- [ ] Single signing path: assert NATS submit and gRPC submit both funnel `sign_and_submit`.
- [ ] Forged envelope under enforcement → no Vault call, no Solana submit, audit records rejection.
- [ ] Dedup: same `idempotency_key` twice → one on-chain tx, second replays stored result.
- [ ] PolicyEngine reject → audit stage recorded, no submit.

### End-to-end (`just e2e` / `just openadr-e2e` style)
- [x] Meter reading → ingest 200/202 → bin → settlement → `chain.tx.submit` published.
      — covered by `30_settlement/test_path_b_generation_mint.py` PASS 2026-06-13.
- [x] chain-bridge consumes → Vault sign → simnet submit → `TxResultMessage` on reply subject.
      — same PASS: on-chain GRID delta confirmed, so consume→sign→submit→reply round-tripped.
- [ ] Unregistered meter (no Redis pubkey) → rejected at ingress, no settlement.
- [x] Path-degradation: unset `NATS_URL` with `MINT_VIA_CHAIN_BRIDGE=true` → WARN logged + metric `settlement_path{path="grpc"}`.
      — `30_settlement/test_settlement_path_degradation.py` PASS 2026-06-13: clones live
      aggregator wiring into a throwaway container minus `NATS_URL`, asserts
      `settlement_path{path="grpc"} 1` + the "NATS_URL is unset" WARN, self-teardown.

## Rollout
- [ ] Land Phase 1+2 behind enforcement flag flip in staging first.
- [ ] Watch `nats_auth_*` + `settlement_path` metrics 24h before prod default flip.
- [ ] Prod: set `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true`.
