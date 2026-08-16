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

## If we proceed: three candidate designs

| # | Design | Mapping owner | Failure mode when the mapping is stale |
| - | ------ | ------------- | -------------------------------------- |
| A | SPIFFE identity → allowed serial prefix/zone | static config in the bridge | new meter in an existing zone works; new zone rejects until redeployed |
| B | SPIFFE identity → explicit serial set, in the meter registry | meter-service registration API | every newly registered meter is rejected until the mapping is written — highest blast radius |
| C | **Log-and-measure only**: record `(spiffe_id, serial)` pairs, emit a metric on mismatch, reject nothing | none | none — but enforces nothing |

**C is the recommended first step regardless of the eventual target.** It costs little, and it
answers the question this plan cannot answer from the code alone: *how often does a gateway
legitimately submit for a serial nobody expected?* Without that number, A and B are guesses about
blast radius, and the fail-closed cost above is unquantified.

## Ordered steps

1. **Decide the mapping owner** — this is the blocking decision, not a code task. If no service
   plausibly owns "which gateway may speak for which meters", stop here and close as won't-do.
2. **Implement C** (observability only). Read `VerifiedSpiffeUri` in the ingest handlers
   (`crates/aggregator-api/src/handlers.rs`: `ingest_private_network`,
   `ingest_private_network_batch`) and emit a counter keyed on match/mismatch against whatever
   provisional mapping step 1 chose. Reject nothing. Ship it and let it run.
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
