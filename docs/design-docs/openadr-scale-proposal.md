# Proposal: Full-Feature, Large-Scale OpenADR 3.x for GridTokenX

> Status: **Proposal / RFC** · Author: WiT · Last reviewed: 2026-06-25
> Scope: superproject (new VTN service + `gridtokenx-aggregator-bridge` changes)
> Related: [core-beliefs.md](core-beliefs.md) · [api-design-guide.md](api-design-guide.md) ·
> bridge [ARCHITECTURE.md](../../gridtokenx-aggregator-bridge/ARCHITECTURE.md)

## 1. Decision summary

Build GridTokenX into a **federated, certification-grade OpenADR 3.x platform**:

1. **Operate our own VTN** (a first-class service) for the GridTokenX fleet — programs,
   events, reports, VENs, subscriptions, resources.
2. **Keep the utility-facing VEN bridge** so the platform can also *consume* upstream
   utility/ISO demand-response signals (federation: we are a VEN to them, a VTN to our fleet).
3. Target **large scale** (10k–100k+ VENs) with push-based delivery, HA, durable state,
   per-VEN auth.
4. Pursue **OpenADR Alliance certification** (VTN + VEN profiles) and pass interop testing.

This is a phased program, not a single change. Phases 1–6 below are independently shippable.

## 2. Where we are today (baseline, cited)

The bridge already runs a **working but minimal OpenADR 3.1 slice**, both roles, client-side
against an *external* VTN (upstream `openleadr-rs` v0.2.4):

**VTN-facing dispatcher** (`gridtokenx-aggregator-bridge/crates/aggregator-logic/src/standards/openleadr.rs`):
- Single program (by id or name-resolve-or-create), `resolve_program` cached
  (`openleadr.rs:154`).
- **One event type only**: `EventType::DispatchSetpoint` (`openleadr.rs:114`).
- Single interval, single optional `Target`, fixed priority 10, OAuth client-credentials
  (one client id/secret).
- Trigger chain is autonomous: fleet telemetry → `FrequencyMonitor` rolling mean
  (`crates/aggregator-logic/src/grid_status.rs:33`) → Kafka `GridStatusEvent` →
  `DispatchEngine.evaluate_and_dispatch` (`crates/aggregator-logic/src/dispatch/engine.rs:133`).
- Decision band: `< 49.8 Hz` → FLEX_UP, `> 50.2 Hz` → FLEX_DOWN (`engine.rs:142`); per-action
  cooldown 900 s (`engine.rs:41`); capacity gate requires ≥1 completed aggregation bin
  (`engine.rs:198`).

**Utility-facing VEN** (`crates/aggregator-logic/src/standards/openleadr_ven.rs:47`):
- **Polling** listener (no push/subscription), self-registers a VEN object at startup.
- Consumes `DISPATCH_SETPOINT` events, executes via `ieee` (sim stub) or `grpc` adapter,
  posts execution reports, dedups by id + `modificationDateTime`, handles multi-interval.

**Adapter abstraction**: `DispatchAdapter` trait with `is_simulation()`
(`crates/aggregator-logic/src/standards/mod.rs`).

**Honest gaps**: no own VTN, one event/report type, polling not push, single-tenant auth,
in-memory dispatch state (`last_dispatch` Vec, `FrequencyMonitor` deque — not durable, not
HA), `ieee` adapter is a logging stub (no real actuation), no M&V/baseline, no conformance
test harness.

## 3. Gap analysis vs full OpenADR 3.x

| Capability | Spec (3.0/3.1) | Today | Gap |
| --- | --- | --- | --- |
| **VTN service** | Full REST resource model | none (external VTN) | **Build it** |
| Event types | SIMPLE, PRICE, LOAD_CONTROL, IMPORT/EXPORT_CAPACITY_LIMIT/SUBSCRIPTION/NOMINATION, CHARGE_STATE_SETPOINT, DISPATCH_SETPOINT… | DispatchSetpoint only | Multi-type model + payload descriptors, units, randomization, ramp |
| Programs | many, lifecycle mgmt, intervals, targets | one, hardcoded name | Program catalog + CRUD + scheduling |
| Reports | report *requests*, telemetry/usage/availability, granularity, histograms | VEN posts execution only; VTN collects none | Full report request/collection + storage + query |
| Subscriptions | webhook push (objectOperation callbacks) | polling only | Push delivery + subscription registry + ret/backoff |
| VEN/Resource model | VENs, nested resources, attributes, targeting groups | flat VEN, single target | Resource hierarchy + group targeting + attributes |
| Auth | OAuth2 client-creds, scopes, per-VEN identity, TLS | single client id/secret | Per-VEN credentials, scoped tokens, mTLS, rotation |
| State/HA | durable, horizontally scalable | in-memory, single instance | Postgres-backed state + multi-instance coordination |
| Actuation | real DER control | `ieee` is a sim stub | Real downstream control (gRPC/IEEE 2030.5 DERControl) |
| M&V / settlement | baselines, performance measurement | none | Baseline engine + performance → existing billing/mint path |
| Conformance | OpenADR Alliance test suite | none | Conformance harness + certification |

## 4. Target architecture (hybrid, federated)

```
        Upstream utility / ISO VTN
                  │  (OpenADR 3.x, push+poll)
                  ▼
        ┌─────────────────────┐
        │  Aggregator Bridge  │  ← VEN of upstream (existing openleadr_ven.rs, upgraded)
        │  (VEN + telemetry)  │
        └─────────┬───────────┘
                  │ internal flex intents (Kafka GridStatusEvent / gRPC)
                  ▼
        ┌─────────────────────┐
        │  GridTokenX VTN svc  │  ← NEW first-class service (programs/events/reports/
        │  (own fleet VTN)     │     VENs/subscriptions/resources, HA, Postgres-backed)
        └─────────┬───────────┘
                  │ OpenADR 3.x (push to subscribers, poll fallback)
                  ▼
   10k–100k+ fleet VENs (smart meters, EVSE, batteries, VPP nodes)
                  │ execution reports + telemetry
                  ▼  → M&V baseline → settlement/mint (existing chain-bridge path)
```

Key boundaries:
- **New service** `gridtokenx-vtn-service` (own Cargo workspace, submodule) — follows the
  platform's sync-core/async-edges + `server → api → logic → persistence → core` rule
  ([core-beliefs.md](core-beliefs.md)). Reuse `openleadr-wire` types; either embed
  `openleadr-rs` VTN crate or implement the REST surface natively for full control.
- **Bridge** stays the telemetry/aggregation/dispatch brain; it *feeds* the VTN (publishes
  flex intents) instead of talking to an external VTN directly for internal dispatch. The
  existing `OpenLeadrAdapter` repoints at our VTN; the existing VEN listener stays for
  upstream federation.
- **No new blockchain coupling** — VTN is chain-light; settlement still flows through the
  bridge's existing mint/settlement sink.

## 5. Scale & reliability design

- **Push over poll**: implement OpenADR subscriptions (webhook callbacks on object
  operations) so 100k VENs don't poll-storm. Keep poll as degraded fallback (the bridge
  VEN already polls — generalize it). Delivery: outbox table + worker pool + exponential
  backoff + dead-letter.
- **Durable state**: move dispatch/event/report/VEN state to Postgres (pgdog-fronted, as
  the rest of the platform). Replace in-memory `last_dispatch`/`FrequencyMonitor` with
  durable + cache-in-Redis so multiple VTN/bridge instances coordinate (idempotency keys,
  optimistic locking).
- **Horizontal scale**: stateless VTN API replicas behind APISIX; event fan-out via Kafka
  partitioned by program/target; subscription delivery workers scale independently.
- **Backpressure & idempotency**: per-VEN delivery queues, event id + modificationDateTime
  dedup (already done VEN-side — promote to a shared library), bounded retries.
- **Multi-tenancy/targeting**: resource groups + attribute-based targeting so one event
  addresses a cohort, not N events.
- **Observability**: extend existing dispatch metrics (`engine.rs` `record_dispatch_outcome`)
  with per-program/per-VEN delivery, ack latency, report-completeness SLOs.

## 6. Security at scale

- **Per-VEN identity**: OAuth2 client-credentials per VEN (not one shared client), scoped
  tokens (`read_events`, `write_reports`, `write_vens_ven`, …), short TTL + rotation.
- **mTLS** for VTN↔VEN where the deployment supports it (reuse the platform's dev CA +
  `just gen-certs` pattern; align with bridge's existing mTLS client-cert envelope signing).
- **Fail-closed** posture consistent with the bridge's signature-verification invariants
  (no silent accept). Authz on every VTN resource by VEN identity + program membership.
- **Replay/idempotency**: signed, deduped report ingestion; reuse the bridge's
  idempotency-key discipline.

## 7. OpenADR Alliance certification roadmap

1. Choose profiles: **VTN** + **VEN** (3.0 baseline; 3.1 where the cert suite supports it).
2. Implement the **mandatory** resource set + behaviors for each profile (events, reports,
   subscriptions, programs, vens, resources, auth).
3. Stand up the **conformance test harness** in CI (alongside `just openadr-e2e`); treat
   conformance vectors as gating tests.
4. Self-test → pre-cert interop (test against ≥2 independent VTN/VEN impls, incl.
   `openleadr-rs`) → Alliance certification submission.
5. Maintain: pin spec version, add a conformance regression suite to the docs-lint/CI gate.

## 8. Phased plan (independently shippable)

| Phase | Deliverable | Rough effort |
| --- | --- | --- |
| **0. Foundation** | New `gridtokenx-vtn-service` skeleton (workspace, crates, health, APISIX route, compose + healthcheck). Repoint bridge `OpenLeadrAdapter` at it. | S–M |
| **1. Core VTN resources** | Programs, events, vens, reports REST (Postgres-backed), name-resolve semantics ported from `openleadr.rs:154`. | M–L |
| **2. Event richness** | Multi event-type model (PRICE/LOAD_CONTROL/CAPACITY_LIMIT/…), payload descriptors, units, intervals, randomization, ramp, group targeting. | M |
| **3. Push delivery** | Subscriptions + webhook delivery (outbox/worker/backoff/DLQ); poll fallback. Generalize VEN dedup into shared lib. | M–L |
| **4. Reports & M&V** | Report requests + collection + storage/query; baseline + performance measurement feeding the bridge settlement/mint path. | L |
| **5. Scale & HA** | Durable dispatch state, multi-instance coordination, Kafka fan-out, per-VEN auth + mTLS + rotation, load test to target VEN count. | L |
| **6. Certification** | Conformance harness in CI, interop testing, Alliance submission. | L |

(Effort: S≈days, M≈1–2 wk, L≈3 wk+, single-dev rough order.)

## 9. Risks & mitigations

- **`openleadr-rs` feature coverage** may lag full spec → budget for native REST
  implementation of gaps; keep wire types from `openleadr-wire` for compatibility.
- **Scope creep across services** → enforce phase boundaries; each phase ships + tests
  before the next (test-first rule).
- **`ieee` adapter is a sim stub** (`mod.rs` `is_simulation`) → real actuation is Phase 4+
  work; until then reports must keep honestly flagging simulated dispatch (already enforced).
- **State migration risk** (in-memory → durable) → dual-write + shadow-read before cutover.
- **Cert moving target** → pin a spec revision; gate on conformance regression suite.

## 10. Testing & conformance gates

- Extend `scripts/openleadr-e2e.sh` / `just openadr-e2e` (current full-loop e2e) into a
  **suite**: per-event-type, push-delivery, report-collection, multi-VEN fan-out, auth-reject.
- Add a **conformance harness** running OpenADR Alliance vectors in CI.
- Load test (Phase 5) to the agreed VEN count; assert delivery latency + report-completeness
  SLOs.
- Keep the docs-lint gate green (`just lint-docs`): every architectural claim cited
  `path:line`, every relative link valid.

## 11. Open questions for review

- Embed `openleadr-rs` VTN crate vs native REST implementation for full control?
- Target VEN count + hardware budget for the Phase 5 load test?
- Which event types are in scope for v1 (PRICE + LOAD_CONTROL likely first)?
- Settlement coupling: does DR performance settle on-chain via the existing mint path, or
  off-chain first?
