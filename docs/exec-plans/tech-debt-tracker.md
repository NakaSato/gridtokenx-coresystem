# Tech Debt Tracker

Running ledger of known shortcuts, deferred work, and architectural debt. Each item has an owner-
intent, a blast radius, and a trigger that says when it must be paid down.

Status legend: 🔴 blocking · 🟠 should-fix · 🟢 nice-to-have · ✅ paid down

| ID | Item | Area | Severity | Trigger to pay down | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| TD-001 | _example_ — direct DB call bypassing repository layer | trading | 🟠 | before next settlement refactor | open |
| TD-002 | Settlement settles a freshly-completed bin before late readings arrive → strands energy | aggregator | 🟢 | before onboarding intermittent/offline-buffered meters | mitigated (boundary case) |
| TD-003 | IoT edge has no transport-level mTLS — Envoy `:4002` edge removed 2026-06-14; device auth is Ed25519-only at the Aggregator | edge | 🟡 | before any IoT device traffic needs a transport-mTLS boundary | graduated → [`active/0001-iot-edge-mtls.md`](active/0001-iot-edge-mtls.md) |
| TD-004 | meter-service reads aggregator-owned read-model tables directly (cross-domain coupling); register-time wallet leans on a user-edge fallback to cover async feed lag | meter / aggregator | 🟠 | before the aggregator owner read-model feed becomes the sole owner path (prod cutover) | mitigated (fallback `c6aa96b`; feed enabled live) |

### TD-003 — Envoy `:4002` mTLS edge is an unenforced plaintext stub

Docs (superproject `CLAUDE.md`, README port table) describe **Envoy `:4002` as the IoT/mTLS edge**, but
the only Envoy config in the tree — `envoy_conf/envoy.yaml` — is a self-declared dev **stub**: one
plaintext HTTP listener returning `direct_response: 200 "ok"`, with no `transport_socket`, no
`require_client_certificate`, no CA. The file's own header says "NOT a real mTLS/IoT edge config —
replace before relying on the `:4002` edge path."

- **Verified (2026-06-13):** `http://localhost:4002/` → `200 server:envoy`; `https://localhost:4002/`
  → curl `000` (TLS ClientHello hitting a plaintext listener, *not* an mTLS rejection).
- **Risk:** anything pointed at `:4002` as a trusted mTLS boundary is, in this build, an open plaintext
  endpoint. The device-identity trust story for the IoT edge is **not** enforced at the gateway here;
  the Aggregator's Ed25519 signature check is the only real device-auth in the path.
- **Surfaced by:** the E2E_IMPL "Envoy mTLS enforcement" item, which is BLOCKED on this (a non-mTLS
  reject can't be asserted while the listener is plaintext).
- **Pay-down:** author a real Envoy mTLS listener (CA + `require_client_certificate`, SPIFFE SAN
  like the chain-bridge edge), wire `scripts/gen-certs.sh` material, then unblock the e2e.
- **Enforcement landed** (2026-06-13, `envoy_conf/envoy.yaml` + docker-compose cert mounts):
  `:4002` now requires a client cert chaining to `infra/certs/ca.crt`
  (`require_client_certificate: true`). Verified by `tests/e2e/80_gateways/test_envoy_mtls.py`
  (3/3): plaintext → rejected, clientless TLS → handshake fail, CA-signed client cert → `200 "ok"`.
  **Routing landed** (2026-06-13, same `envoy.yaml`): the `direct_response` stub is replaced by an
  `aggregator_iot` STRICT_DNS cluster → `aggregator-bridge:4010` (shared `edge-tier` +
  `gridtokenx-network`). Verified: a mTLS client GET `/health` through `:4002` returns the real
  Aggregator IoT-gateway health JSON (`service: gridtokenx-iot-gateway`), not a stub —
  `test_envoy_mtls.py::test_https_with_client_cert_proxied_to_aggregator`.
  **Residual (still open, narrowed):** the client SPIFFE SAN is not yet mapped to a device/role at the
  edge (no SAN→identity header injection like chain-bridge's `PeerCertLayer`); the Aggregator's own
  API-key + Ed25519 checks remain the device-auth of record. Full close = SAN→identity propagation.
  **Reopened (2026-06-14):** the Envoy `:4002` edge was **removed entirely** (service deleted from
  `docker-compose.yml`, `envoy_conf/` deleted, scripts/e2e/env scrubbed). IoT devices now ingress
  **directly** to the Aggregator Bridge IoT gateway with **no transport-level mTLS edge at all**. The
  Aggregator's API-key + Ed25519 signature verification is now the *sole* device-auth boundary. If a
  transport-mTLS boundary for IoT traffic is later required, it must be re-introduced (terminate at the
  Aggregator itself, or a replacement edge proxy) — the prior Envoy mTLS listener + routing work is gone.
  **Correction (2026-07-22):** "no transport-mTLS **at all**" is now stale — it described the deleted
  Envoy edge. The "terminate at the Aggregator itself" option has since **landed but is disabled**:
  `build_mtls_server_config` (WebPkiClientVerifier, requires+verifies client certs,
  `gridtokenx-aggregator-bridge/src/main.rs:59-101`) is wired (`src/main.rs:1377-1394`) and gated on
  `IOT_GATEWAY_TLS_CLIENT_CA`, which compose leaves empty (`docker-compose.yml:849`). Server-auth TLS
  on `:4010` **is** live. gen-certs already emits the server cert + 9 SPIFFE client certs
  (`scripts/gen-certs.sh:97,104-126`). Real residual = (1) enforcement off in every profile, (2) no
  SAN→identity propagation (TLS path uses `into_make_service()`, drops the peer cert), (3) no e2e.
  **Graduated:** scoped into [`active/0001-iot-edge-mtls.md`](active/0001-iot-edge-mtls.md).

### TD-002 — partial-bin settlement strands energy on late telemetry

`SettlementEngine::process_completed_bins` peeks any bin with `end_time <= now` and mints + evicts
it (`settlement_engine.rs:129-177`, `aggregator.rs::peek_completed_bins`). A reading whose timestamp
falls in an **already-closed** window creates an instantly-"completed" bin, so the next 60s tick
settles whatever partial energy is present and creates the on-chain `gen_mint` PDA
`[b"gen_mint", meter_id, window_start_ms]`. Any later reading for the **same (meter, window)** then
re-creates the bin, but the mint is a PDA no-op (`init_if_needed`) → that energy is **stranded
(under-minted)**. Correctly NOT a double-mint — the PDA guards over-mint; this is the inverse.

- **Blast radius:** prosumers on intermittent/offline-buffered meters that reconnect and replay
  backdated telemetry for a window that already settled. Real-time meters are unaffected (their bins
  complete only after the window closes, by which point all readings have arrived).
- **Surfaced by:** `tests/e2e/30_settlement/test_settlement_idempotency.py` — a multi-reading window
  observed minting only the first reading (20 of 50 kWh); the test uses a single reading to dodge it.
- **Candidate fix:** a settle grace period (don't settle a bin whose window closed < N s ago), or
  route a late reading hitting an already-settled (meter, window) into a correction / next window.
  Design change — not an ad-hoc patch.
- **Mitigation landed** (aggregator `431246e`, unpushed submodule commit): `peek_completed_bins` now
  takes a grace `Duration` and returns only bins whose window closed ≥ grace ago; `SettlementEngine`
  reads `SETTLEMENT_GRACE_SECS` (default 120). This closes the **boundary-lateness** case — readings
  arriving shortly after a window closes now land before it settles. **Residual (still open):** a
  *truly-late* replay (an offline meter resending hours after the window already settled) re-creates a
  bin whose mint is a PDA no-op → that energy is still stranded. Severity dropped 🟠→🟢; full close
  needs the late-reading-correction routing above.

### TD-004 — register-time wallet leans on a fallback; owner read-model feed is off by default

meter-service resolves a meter's owner wallet by reading two **aggregator-owned** read-model tables
in `meter_select` (`gridtokenx-meter-service/crates/meter-persistence/src/repository/meter.rs:33`):
`meter_owner_read_model` (serial→wallet) and, since `c6aa96b`, `user_wallet_read_model` (user→wallet).
Cross-domain table coupling in the DB-per-service split — meter-service reads tables another service
owns and migrates (aggregator `migrations/0006`/`0007`).

- **Symptom paid down:** the serial→wallet row is populated **asynchronously** by the aggregator's
  Kafka owner read-model feed (`AGGREGATOR_OWNER_READMODEL_FEED`,
  `gridtokenx-aggregator-bridge/crates/aggregator-persistence/src/infra/owner_read_model.rs:373`).
  The feed is **off by default in code** but **enabled in this deployment** (`docker-compose.yml:796`,
  split brokers `meter_events@kafka-market` + `iam.user.events@kafka-cmd` — verified live: log
  `🗃️ Owner read-model feed ENABLED`, consumers upserting serials + wallets). It still lags the
  synchronous register call: at `register_meter`'s re-select the aggregator has not yet consumed the
  just-emitted `MeterRegistered`, so the serial row is briefly absent and the meter surfaced a blank
  `wallet_address` in the register response, `/me/meters`, and the emitted event.
- **Mitigation landed** (`c6aa96b`): `meter_select` falls back to the durable user→primary-wallet
  edge (`user_wallet_read_model`, written by IAM events independent of meter ownership) via a second
  `LEFT JOIN` + `COALESCE(serial_wallet, user_wallet, '')`. Verified live — DB-gated e2e
  `http_e2e_register_surfaces_wallet_from_user_edge` (17/17 e2e green against `gridtokenx_meter`).
- **Blast radius:** none today — the feed is enabled and the user-edge fallback covers the async
  register-time gap. Debt is the **cross-domain table coupling** (meter-service `meter_select` reads
  two aggregator-owned tables) plus the feed's transient-fault surface (observed live: the IAM
  consumer logged `AllBrokersDown` and self-healed — a longer broker outage stalls owner updates
  until recovery + backfill).
- **Residual / pay-down:** either (a) validate the enabled feed under fault (broker restart, replay)
  and cut the legacy `meters ⋈ users` reads (see
  `gridtokenx-aggregator-bridge/docs/db-split-phase2.md` §5), or (b) give meter-service its own
  owner/wallet projection instead of reading aggregator-owned tables. Must be resolved before the feed
  becomes the sole owner path at prod cutover.

## How to use

1. Add a row when you knowingly take a shortcut. Reference the commit or PR that introduced it.
2. Severity reflects risk if left unpaid, not effort to fix.
3. The **trigger** is the condition that converts the debt from "tolerated" to "must fix now" —
   usually a feature that would compound it.
4. Move resolved items to ✅ with the paying commit; keep them for one quarter, then prune.

## Sources to mine for debt

- [`../gridtokenx-refactor-checklist.md`](../gridtokenx-refactor-checklist.md)
- [`../gridtokenx-refactor-plan.md`](../gridtokenx-refactor-plan.md)
- `cargo clippy -- -D warnings` output across services
- `// TODO` / `// FIXME` / `// HACK` markers in service code
