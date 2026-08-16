# Tech Debt Tracker

Running ledger of known shortcuts, deferred work, and architectural debt. Each item has an owner-
intent, a blast radius, and a trigger that says when it must be paid down.

Status legend: 🔴 blocking · 🟠 should-fix · 🟢 nice-to-have · ✅ paid down

| ID | Item | Area | Severity | Trigger to pay down | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| TD-001 | _example_ — direct DB call bypassing repository layer | trading | 🟠 | before next settlement refactor | open |
| TD-002 | Settlement settles a freshly-completed bin before late readings arrive → strands energy | aggregator | 🟢 | before onboarding intermittent/offline-buffered meters | mitigated (boundary case) |
| TD-003 | IoT edge transport-level mTLS — terminates at the Aggregator, enforced in the secure profile, SPIFFE identity propagated to handlers | edge | 🟡 | — | closed 2026-08-16 → [`completed/0001-iot-edge-mtls.md`](completed/0001-iot-edge-mtls.md) |
| TD-004 | meter-service reads aggregator-owned read-model tables directly (cross-domain coupling); register-time wallet leans on a user-edge fallback to cover async feed lag | meter / aggregator | 🟢 | before rec-A (one shared `gridtokenx_meter`) is revisited — see rec-B | narrowed to one contract table (2026-07-27); circular read removed |

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
  **Graduated:** scoped into [`completed/0001-iot-edge-mtls.md`](completed/0001-iot-edge-mtls.md).
  **Closed (2026-08-16):** all three residuals paid.
  (1) Enforcement ships in the secure profile — `secure.env:19` sets
  `IOT_GATEWAY_TLS_CLIENT_CA=/app/infra/certs/ca.crt` (Phase 6 of
  [`../telemetry-security.md`](../telemetry-security.md)); this had in fact landed before the plan
  was written, which the plan did not know.
  (2) SAN→identity propagation exists: the mTLS serve path swapped
  `bind_rustls`+`into_make_service()` (which discards the peer cert) for `MtlsAcceptor`, and
  `peer_cert_identity` republishes the SPIFFE URI as a `VerifiedSpiffeUri` extension +
  `z-gridtokenx-spiffe-id` header —
  `gridtokenx-aggregator-bridge/crates/aggregator-api/src/middleware/mtls.rs`.
  (3) e2e: [`../../tests/e2e/25_iot_mtls/`](../../tests/e2e/25_iot_mtls/) asserts the transport cases;
  the identity-reaches-handler leg is a Rust test driving a real handshake (same module).
  **Residual — accepted, closed 2026-08-16.** The propagated identity is **published and not
  consumed**: no handler authorizes on it, so API-key + Ed25519 remain the device-auth of record and
  the mTLS layer is defence-in-depth. That is now the **intended end state**, not a gap.
  [`completed/0002-mtls-identity-as-authorization.md`](completed/0002-mtls-identity-as-authorization.md)
  investigated making it an authorization input and closed **won't-do**: certs are per-*service* and
  a gateway fronts many meters, so it is a serial-**scope** problem rather than an identity equality;
  Ed25519 already binds what a frame may claim; and a reject-at-ingest rule keyed on a lookup cuts
  against the meter registry's deliberate degraded-safe design. Two findings from that work are worth
  carrying: `api_keys.permissions` already exists as a per-client IoT scope but is dropped by the
  proto (`ApiKeyResponse` omits it) and the aggregator discards `role` as well, caching only
  `valid: bool` — so any future per-client ingest authorization should widen **that** path; and a
  SPIFFE→serial map is recorded as considered-and-rejected.
  Device cert issuance/rotation also stays dev-CA manual; production PKI (SPIFFE/SPIRE or
  Vault-issued device certs) is unscoped.

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

### TD-004 — meter-service reads read-model tables another service owns and migrates

> **Superseded in part (2026-07-27).** The history below is kept as written — it was accurate at the
> time and explains why the fallback exists. What changed: the circular `meter_owner_read_model` read
> is gone and the remaining coupling is one explicit contract table. Read the **Narrowed** bullet at
> the end of this section for the current state.

meter-service resolved a meter's owner wallet by reading two **aggregator-owned** read-model tables
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
- **Broker-restart fault validated** (2026-07-25): restarted `kafka-cmd`, published a synthetic
  `UserWalletLinked` for a test user across the outage. The IAM consumer logged `AllBrokersDown`
  (2/2 down) without crashing, reconnected on broker return, and applied the event ~1 min later
  (`update_wallet_by_user` → row landed in `user_wallet_read_model`; aggregator stayed `healthy`
  throughout). No loss — the event rode Kafka's durable log + `earliest`-offset replay. Confirms the
  self-heal loop (`OwnerReadModelConsumer::run`) and durability backstop.
- **Narrowed (2026-07-27).** The two pay-down options this entry used to name were both wrong:
  (a) "cut the legacy `meters ⋈ users` reads" was already done — the swap landed flag-gated on
  `own_meter_db` (`gridtokenx-aggregator-bridge/src/main.rs:193`) and is live in compose
  (`docker-compose.yml:795`); (b) "give meter-service its own projection" would not have decoupled
  anything, because the aggregator is the only migration applier
  (`sqlx::migrate!("../../migrations")`,
  `gridtokenx-aggregator-bridge/crates/aggregator-persistence/src/infra/db.rs:23`) — meter-service's
  `migrations/0001_meter_registry.sql` is applied by nothing. A "meter-service-owned" table would
  still need its DDL in the aggregator's set, plus a second Kafka consumer building a near-identical
  projection of the same IAM events. That is duplication, not decoupling.
- **What was actually wrong:** of the two joins, only one was debt. `meter_owner_read_model` is the
  aggregator's private serial→(user, wallet) projection, which it builds by consuming the very
  `MeterRegistered` events meter-service emits — so meter-service reading it was **circular**: asking
  another service to re-derive its own `meters.user_id`, which it is the sole writer of. Removed
  (`gridtokenx-meter-service/crates/meter-persistence/src/repository/meter.rs`). Owner wallets now
  resolve through `user_wallet_read_model` keyed on the local `meters.user_id`, at both read sites —
  `list_map_meters` previously had **no** fallback at all, so it blanked the wallet on the map for any
  meter whose serial row the async feed had not yet written.
- **Writer-side hole this exposed:** both backfills only ever flowed serial-ward
  (`meters ⋈ users` / `meters ⋈ user_wallet_read_model` → `meter_owner_read_model`), and
  `repair_missing_wallets` only targets NULL wallets. So an owner whose wallet arrived via a backfill
  rather than a live IAM event had a wallet on the serial row and **no** `user_wallet_read_model` row
  — permanently invisible, and now blanking. Closed by `backfill_user_edge`
  (`crates/aggregator-persistence/src/infra/owner_read_model.rs`), a non-regressing
  `ON CONFLICT DO NOTHING` seed of the reverse edge; pinned by
  `tests/owner_read_model_repo.rs::backfill_seeds_the_reverse_user_wallet_edge` (verified to fail
  without the fix).
- **Residual — this is the rec-A ceiling, not an oversight.** meter-service now reads exactly one
  table it does not own: `user_wallet_read_model`. IAM owns wallets, both metering services need
  user→wallet, and under rec-A (§3.5: ONE shared `gridtokenx_meter`) the alternative is two consumers
  maintaining two copies of the same projection. It is now an explicit **contract**: writer-side DDL
  mirrored at `gridtokenx-meter-service/contracts/user_wallet_read_model.sql` and guarded against
  drift by `scripts/check-metering-ddl-sync.sh` (`just check-ddl-sync`), so a writer-side shape change
  fails a check instead of breaking a service that never migrates. **Full closure requires rec-B**
  (separate physical DBs per service) — a deliberate re-opening of the resolved rec-A decision, not
  in scope here.
- **Still untested (unchanged):** a broker outage longer than Kafka retention, and cross-topic replay
  ordering. The broker-restart fault is validated (above).

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
