# 0002 — Make the mTLS identity an authorization input (TD-003 residual)

> Follows [`../completed/0001-iot-edge-mtls.md`](../completed/0001-iot-edge-mtls.md) · Status: **not started**
> Owner: platform / aggregator · Severity: 🟢 (see "Should we do this at all?" — this may be a decline)

## Goal

Plan 0001 made the IoT gateway verify a client certificate and publish its SPIFFE identity to
handlers. **Nothing consumes it.** This plan decides whether — and how — that identity becomes an
authorization input rather than an attributable log line.

Read the next section before scoping any work. The naive framing of this task is wrong, and the
honest answer may be "don't".

## The framing that does not survive contact with the code

The tempting one-liner is "bind `meter_serial` to the certificate's SPIFFE identity". That assumes
one cert per meter. The tree says otherwise:

- `scripts/gen-certs.sh` issues **9 per-service identities** (`spiffe://gridtokenx.th/prod/<service>`),
  not per-device ones. The meter-side identity in use is a single
  `smartmeter-simulator` cert covering the entire simulated fleet.
- [`../../../gridtokenx-aggregator-bridge/GATEWAY.md`](../../../gridtokenx-aggregator-bridge/GATEWAY.md)
  describes the client as an **edge concentrator** forwarding many meters over one connection. That
  is the intended deployment shape, not an artefact of the simulator.
- There is **no** gateway→serial mapping anywhere in the service today (no `gateway_id`,
  `allowed_serial`, or equivalent in `gridtokenx-aggregator-bridge/crates/`).

So the cardinality is **one identity : many serials**, and the real question is a *scope*: which
serials may this identity submit for? That is a different, larger problem than an equality check,
and it needs an owner for the mapping before any code is written.

## Should we do this at all?

State the marginal value honestly, because it is smaller than it first appears.

Every reading on the verified route already carries a **per-device Ed25519 signature** checked
against that device's pubkey in Redis (`crates/aggregator-persistence/src/infra/crypto.rs`). A
frame's right to claim a serial is therefore *already* cryptographic and not positional. Serial
scoping adds exactly two things on top:

1. **Containment of a stolen device key.** Today a leaked meter key can be replayed from anywhere
   that holds any valid API key + client cert. With scoping, it can only be replayed from a gateway
   already authorized for that serial.
2. **Containment of a compromised gateway.** One gateway could not assert *another* gateway's
   serials.

Both are real but narrow. Weigh them against a concrete cost: the meter registry is **deliberately
degraded-safe** — an unattributable reading is counted and dropped at write time, never rejected at
ingest, precisely so a registry outage cannot become permanent telemetry loss
(`aggregator_readings_unattributed_total`, see the aggregator's CLAUDE.md). A serial-scope check is
by definition a **reject-at-ingest** rule keyed on a lookup, which cuts directly against that
design. Get it wrong and a registry blip silently discards real energy that then never settles or
mints.

**A defensible outcome of this plan is to close it as "won't do", keeping the identity as
attribution + logging only.** Do not treat implementation as the default.

## Step 1 is already answered: IAM owns it, and the mechanism exists but is thrown away

Investigated 2026-08-16. **Do not invent a SPIFFE→serial map.** A per-client credential scoped to
an IoT caller already exists end to end — it is simply discarded, at two separate layers:

1. **The schema has the scope.** `api_keys`
   (`gridtokenx-iam-service/migrations/20260325000002_create_api_keys.sql`) carries
   `role VARCHAR(20) DEFAULT 'ami'` **and `permissions TEXT[]`**, seeded `'{"*"}'`, under the table
   comment *"Stores API keys for IoT devices and external services"*. That is precisely a
   per-gateway authorization scope, already owned by IAM, already provisioned per client.
2. **The proto drops `permissions`.** `ApiKeyResponse` is
   `{ bool valid, string role, string error_message }`
   (`gridtokenx-iam-service/crates/iam-protocol/proto/identity.proto:106`) — the permissions array
   never crosses the wire.
3. **The aggregator drops `role` too.** `auth.rs` normalizes the whole round-trip to a single
   `valid: bool` and caches that (`crates/aggregator-api/src/auth.rs:141,157,173`); the auth policy
   has exactly three cases (valid / invalid / transient IAM failure). No scope reaches a handler.

So the honest statement of the residual is not "the mTLS identity is unused" — it is **"the API-key
scope is unused, and the mTLS identity is a second unused identity layered over it."** Building a
SPIFFE→serial map would be a *third* client-identity system stacked on two that already exist and
are ignored. The aggregator is already an authorized `VerifyApiKey` caller (IAM's RBAC allowlist:
ApiGateway / AggregatorBridge / Admin), so no new trust relationship is needed either.

### Revised designs

| # | Design | Where the work lands | Failure mode when the mapping is stale |
| - | ------ | -------------------- | -------------------------------------- |
| A | **Widen the existing API-key scope**: expose `permissions` in `ApiKeyResponse`, carry it through the aggregator's auth cache, check submitted serials against it | IAM proto + `auth.rs` + handlers | a key whose permissions were never populated rejects its whole fleet — mitigate by treating an **empty** array as "unscoped", so existing keys are unchanged |
| B | SPIFFE identity → explicit serial set in the meter registry | new mapping table + meter-service | duplicates A with a second identity system; **not recommended** |
| C | **Log-and-measure only**: record `(spiffe_id, api-key role, serial)`, emit a metric on mismatch, reject nothing | `auth.rs` + handlers | none — enforces nothing |

**C first, then A.** C costs little and answers what neither the schema nor this plan can: *how
often does a gateway legitimately submit for a serial nobody scoped it for?* Without that number,
A's blast radius is a guess. B is superseded — record it as considered-and-rejected so it is not
re-proposed.

The mTLS SPIFFE identity's job then settles into something small and well-defined: **bind the API
key to a transport identity**, so a stolen key cannot be replayed from an arbitrary network
location. That is a property plan 0001 already delivers; it does not need serial-level semantics of
its own.

## Ordered steps

1. ~~**Decide the mapping owner.**~~ **Answered 2026-08-16: IAM, via `api_keys.permissions`** — see
   the section above. The remaining decision is narrower and is a *product* call, not an
   architecture one: is per-gateway serial scoping worth operating at all, given Ed25519 already
   binds what a frame may claim? If no, close as won't-do and delete this plan.
2. **Implement C** (observability only). Read `VerifiedSpiffeUri` in the ingest handlers
   (`crates/aggregator-api/src/handlers.rs`: `ingest_private_network`,
   `ingest_private_network_batch`) and emit a counter keyed on `(spiffe_id, api-key role, serial)`.
   Reject nothing. Ship it and let it run.
3. **Read the metric** for a realistic period across a real fleet, not the simulator — the sim uses
   one identity for everything and will report a 100% "mismatch" that means nothing.
4. **Only then** choose A or B, and only if step 3 shows the enforcement would be quiet. Any
   enforcement must state its degraded-mode behaviour explicitly and must not fail closed on a
   *lookup error* (mirror `resolve_multiplier`, which falls back to last-known-good rather than to
   a unity default, for exactly this reason).
5. **Docs** — update `GATEWAY.md` (its closing paragraph already promises "a future serial-to-identity
   binding would key on" the SAN; make that true or retract it), the aggregator `CLAUDE.md`
   invariant added by plan 0001, and TD-003. Run `just lint-docs`.

## Non-goals

- **Per-device certificates.** Issuing and rotating a cert per meter is a PKI programme
  (SPIFFE/SPIRE or Vault-issued device certs), not part of this. The dev CA is manual today.
- **Replacing Ed25519 payload signing.** The cert bounds *who may connect*; the signature binds
  *what a frame may claim*. These are different jobs and the second is not up for removal.
- **The gRPC ingest path.** This plan covers the REST IoT gateway only; the binary v4 frame path has
  its own identity story.

## Done criteria

Either:
- a written decision to close as won't-do, recorded in TD-003; **or**
- step 2 shipped, step 3's measurement recorded here, and an explicit A/B choice with its
  degraded-mode behaviour documented.

"Enforcement turned on" is **not** a done criterion on its own — an enforcement rule whose false-
reject rate was never measured is a telemetry-loss incident waiting to happen.
