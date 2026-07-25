# 0001 — IoT edge transport-mTLS: enable + propagate device identity (TD-003)

> Graduated from [`../tech-debt-tracker.md`](../tech-debt-tracker.md) TD-003 · Status: **not started**
> Owner: platform / aggregator · Severity: 🟡

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
