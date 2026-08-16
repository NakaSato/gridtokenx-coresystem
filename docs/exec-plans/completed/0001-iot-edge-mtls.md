# 0001 — IoT edge transport-mTLS: enable + propagate device identity (TD-003)

> Graduated from [`../tech-debt-tracker.md`](../tech-debt-tracker.md) TD-003 · Status: **done (2026-08-16)**
> Owner: platform / aggregator · Severity: 🟡
>
> See the [retro](#retro-2026-08-16) at the bottom for what diverged from this plan.

## Goal

Turn the **already-built, currently-disabled** IoT-gateway mTLS into an enforced boundary, and
propagate the client certificate identity (SPIFFE SAN) into the request so the Aggregator's app-layer
checks (API-key + Ed25519) become defence-in-depth, not the sole boundary.

Definition of done:

1. A secure profile requires a client cert chaining to the dev CA at IoT ingress; plaintext and
   clientless-TLS are rejected at the transport layer (`WebPkiClientVerifier` already enforces this
   once `IOT_GATEWAY_TLS_CLIENT_CA` is set).
2. The client SPIFFE SAN is extracted and injected downstream (request extension / header) — parity
   with chain-bridge's `PeerCertLayer`. Requires switching the TLS serve path off
   `into_make_service()` (which drops the peer cert) onto a peer-cert-capturing acceptor.
3. Aggregator API-key + Ed25519 checks remain, now behind the mTLS boundary.
4. An e2e asserts all three transport cases: plaintext → reject, clientless TLS → handshake fail,
   CA-signed client cert → `200` + SPIFFE identity visible to the handler.

## Real state (verified 2026-07-22 — TD-003 narrative is stale)

The tracker's "no transport-level mTLS edge **at all**" describes the deleted Envoy `:4002` edge. Since
then the "terminate at the Aggregator itself" option the tracker named **has landed**:

- **Server-auth TLS is LIVE.** `:4010` serves HTTPS in compose — `IOT_GATEWAY_TLS_CERT`/`_KEY` default
  to the mounted aggregator server cert (`docker-compose.yml:844-845`); serve path
  `gridtokenx-aggregator-bridge/src/main.rs:1377-1421`.
- **mTLS enforcement EXISTS but is OFF.** `build_mtls_server_config` builds a rustls `ServerConfig`
  with `WebPkiClientVerifier` that **requires + verifies** client certs
  (`src/main.rs:59-101`), wired at `src/main.rs:1377-1394`, gated on `IOT_GATEWAY_TLS_CLIENT_CA`.
  Compose leaves it empty (`docker-compose.yml:849` `${IOT_GATEWAY_TLS_CLIENT_CA:-}`) → client cert
  **not required** by default.
- **Certs already exist.** `scripts/gen-certs.sh` emits the aggregator server cert
  (`gen-certs.sh:97`) and **9 SPIFFE client identities** (`spiffe://gridtokenx.th/prod/*`, `clientAuth`,
  URI SAN — `gen-certs.sh:104-126`) against the shared dev CA (`gen-certs.sh:56-57`).
- **Gap 1 — enforcement not enabled** in any shipped profile (client CA env empty).
- **Gap 2 — no SAN→identity propagation.** The TLS serve uses `app.into_make_service()`
  (`src/main.rs:1412`), which does **not** hand the peer cert to handlers. Aggregator has no
  `PeerCertLayer` equivalent, so even with mTLS on, the device's cert identity is invisible above the
  transport — the API-key + Ed25519 checks stay the identity of record.
- **Gap 3 — no e2e.** The deleted `test_envoy_mtls.py` was never replaced for the aggregator path.

## Model to copy (chain-bridge)

- `PeerCertLayer` — Tower layer extracting the SPIFFE URI:
  `gridtokenx-chain-bridge/crates/chain-bridge-api/src/middleware.rs:16`; SAN parse
  `extract_spiffe_id` at `middleware.rs:92`; wired `main.rs:264` `.layer(PeerCertLayer::new())`.
- Peer-cert capture: `MtlsAcceptor` (`harness.rs:71`) + `ConnectionService` (`harness.rs:45`) inject
  `Arc<Vec<Vec<u8>>>` peer certs into request extensions; served via
  `axum_server::bind().acceptor(MtlsAcceptor::new())` (`main.rs:313`) — the pattern that replaces
  `into_make_service()`.

## Affected services / files

- `gridtokenx-aggregator-bridge/src/main.rs` — swap the mTLS serve path (1410-1414) to a peer-cert
  acceptor; add a `PeerCertLayer` equivalent + SAN→identity injection.
- `gridtokenx-chain-bridge/crates/chain-bridge-api/src/{middleware.rs,harness.rs}` — **reference only**.
- `docker-compose.yml:849` — set `IOT_GATEWAY_TLS_CLIENT_CA` in a secure profile.
- `scripts/gen-certs.sh:104-126` — reuse an existing `prod/*` client identity for the meter path (add
  one if a distinct IoT-device SAN is wanted).
- `tests/e2e/` — new transport-mTLS suite (replaces deleted `test_envoy_mtls.py`).

## Ordered steps

1. **Enable mTLS in a secure profile.** Set `IOT_GATEWAY_TLS_CLIENT_CA=/app/infra/certs/ca.crt` in the
   secure compose block; confirm the simulator/meter clients present a `prod/*` client cert
   (`gen-certs.sh:104-126`). Keep dev default OFF (backward-compatible). Reconcile with the always-TLS
   port behaviour ([[aggregator-bridge-always-tls-port]]) and the secure-mode env family
   (`AGGREGATOR_REQUIRE_SECURE`, [[force-surplus-426-secure-mode]]).
2. **Capture the peer cert.** Replace `axum_server::bind_rustls(addr, tls_config).serve(app.into_make_service())`
   (`src/main.rs:1410-1414`) with a chain-bridge-style acceptor that injects the peer-cert chain into
   request extensions (model: `MtlsAcceptor`/`ConnectionService`, `harness.rs:45,71`).
3. **SAN→identity middleware.** Port `PeerCertLayer` + `extract_spiffe_id`
   (`middleware.rs:16,92`) into an aggregator crate (per dependency rule — `aggregator-api`), map SPIFFE
   SAN → device/role, inject as request extension/header. App-layer API-key + Ed25519 unchanged.
4. **E2E.** New suite under `tests/e2e/`: plaintext → reject, clientless TLS → handshake fail,
   CA-signed client cert → `200` + SPIFFE identity present. Wire into the e2e runner. (Assert the
   plaintext case against the "illegal request line" garble, not a clean 4xx — [[aggregator-bridge-always-tls-port]].)
5. **Docs.** Update TD-003 → paying commit + correct the stale "no mTLS at all" narrative; update
   aggregator `CLAUDE.md` / superproject IoT-edge trust text; run `just lint-docs`. Move this file to
   `../completed/` with a retro.

## Risks / notes

- Terminating at the Aggregator couples TLS lifecycle to the service — acceptable; chain-bridge already
  does its own TLS + peer-cert extraction, so this is a proven pattern in-tree.
- **Residual after done:** device cert issuance/rotation stays dev-CA manual; production PKI
  (SPIFFE/SPIRE or Vault-issued device certs) is a separate, larger task — note it, don't scope here.
- Scope is smaller than a green-field edge: the verifier + certs already exist; the real work is
  **enabling** it and **propagating identity** (Gaps 1-3), not building mTLS from scratch.

---

## Retro (2026-08-16)

All four definition-of-done criteria met. Three divergences worth recording:

**Step 1 was already done before this plan was written.** The "Real state (verified 2026-07-22)"
section above says enforcement is enabled in no shipped profile. By the time the work started,
`secure.env:19` already set `IOT_GATEWAY_TLS_CLIENT_CA=/app/infra/certs/ca.crt`, shipped as Phase 6
of [`../../telemetry-security.md`](../../telemetry-security.md) and reachable via `just secure-up`.
Gap 1 had closed independently and nothing updated the plan. **The lesson is the one the
documentation harness already states — re-verify a plan's "real state" before executing it, because
a plan is a snapshot, not a live view.** Only Gaps 2 and 3 were genuinely open.

**Two deliberate improvements over the chain-bridge model.** The plan said to copy `PeerCertLayer`
for parity; the port diverges in two places, both because the aggregator's IoT gateway is
outward-facing where Chain Bridge is in-mesh:
- `peer_cert_identity` **unconditionally strips** an inbound `z-gridtokenx-spiffe-id` before
  deriving its own. Chain Bridge only ever inserts, so a client-supplied header survives when no
  cert is present — harmless there (the header is trusted only behind a dev-gated flag) but a
  latent spoofing hole to inherit at a public ingress.
- `MtlsAcceptor` carries a 10s handshake timeout, matching `axum_server::RustlsAcceptor`'s own
  default. Replacing `bind_rustls` with a hand-rolled acceptor silently drops that bound, which on
  an internet-facing port is a slowloris hole. Chain Bridge has no timeout.

**The e2e is split across two layers, not one.** Step 4 asked one suite to assert all three
transport cases *and* that the SPIFFE identity is visible to the handler. No HTTP endpoint echoes
the identity, and adding one purely for a test would be an information-disclosure surface. So the
transport cases live in [`../../../tests/e2e/25_iot_mtls/`](../../../tests/e2e/25_iot_mtls/) against
the deployed stack (plus a fourth case the plan missed: an *untrusted* client cert, without which a
server that requires certs but never checks the signer would still pass), and the propagation leg is
a Rust test driving a real handshake against a real handler in
`gridtokenx-aggregator-bridge/crates/aggregator-api/src/middleware/mtls.rs`.

Note the e2e **skips** unless the bridge is actually enforcing client certs, since mTLS is off by
default — so its skip is load-bearing and was validated in both directions rather than shipped
never having run green: 4 passed against the deployed bridge started with
`IOT_GATEWAY_TLS_CLIENT_CA=/app/infra/certs/ca.crt`, and 4 skipped against a TLS-only endpoint that
does not request a client cert. The deployed run also confirmed the propagation leg independently of
the Rust test — with `RUST_LOG=debug` the container logged
`verified mTLS peer identity spiffe_id="spiffe://gridtokenx.th/prod/smartmeter-simulator"`, exactly
once, matching the single case that presented a valid certificate.

Finally re-verified under the **composed** secure profile (`just provision-kek` + `secure.env`
layered over `.env`), not just the one mTLS variable in isolation: the bridge came up with at-rest
stream encryption (SEK bootstrapped), Vault Transit key rotation, and mTLS together, and suite 25
passed 12/12 with `IOT_MTLS_REQUIRED=1`. A `POST` to both ingest routes over mTLS with a valid API
key returned `426` — which is the layering working as intended, and worth stating precisely: the
transport check *passed* (a handshake failure would have yielded no HTTP response at all, and a bad
key a `401`), and the app-layer secure-mode check then refused the unsigned `simulator` payload. The
mTLS boundary narrows who may connect; it does not and should not decide what a frame may claim.

**All three serve branches were exercised at runtime, not just the new one.** The change restructured
the enclosing `if let (Some(cert), Some(key))` block, so the two branches it did *not* set out to
change still needed proving — a green `cargo check` says nothing about which branch a deployment
takes. Verified: mTLS (`MtlsAcceptor`) serves a CA-signed client and propagates its identity;
server-auth TLS (`bind_rustls`, `IOT_GATEWAY_TLS_CLIENT_CA` empty — the plain-dev default and the
most common posture) still serves a client presenting **no** certificate with `200`, and logs zero
identity lines, since that path captures no peer cert and must not fabricate one; plaintext
(`IOT_GATEWAY_TLS_CERT`/`_KEY` empty) still serves `200` over HTTP.

**Residual, unchanged from the plan's own note:** the identity is published but nothing consumes it.
Binding `meter_serial` to the cert identity, and production device-cert issuance/rotation (SPIFFE/SPIRE
or Vault-issued), remain separate tasks.
