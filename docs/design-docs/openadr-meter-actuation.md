# Plan: Dispatch Back to the Meter (OpenADR 3 VEN in the Simulator)

> Status: **Plan / awaiting approval** · Author: WiT · Last reviewed: 2026-07-28
> Scope: `gridtokenx-smartmeter-simulator` (new VEN transport) + `gridtokenx-aggregator-bridge`
> (dispatch targeting, phase 3 only)
> Related: [openadr-scale-proposal.md](openadr-scale-proposal.md) ·
> [telemetry-ingest-hops.md](telemetry-ingest-hops.md) · [core-beliefs.md](core-beliefs.md) ·
> bridge [ARCHITECTURE.md](../../gridtokenx-aggregator-bridge/ARCHITECTURE.md)

## 1. Problem

Telemetry flows **meter → bridge** over DLMS/COSEM and is fully closed. The reverse leg —
**bridge → meter** — is built at both ends but has **no terminal actuator**: every dispatch
path terminates in a stub or a private API that nothing calls.

| Leg | Status |
| --- | --- |
| Bridge → VTN (business logic, creates `DISPATCH_SETPOINT` events) | works — `standards/openleadr.rs:92` |
| VTN infrastructure | runs — `openleadr-vtn` compose service, port 4031 |
| Bridge ← VTN (VEN listener, consumes utility setpoints) | works — `standards/openleadr_ven.rs:229` |
| **VTN → meters** | **missing — this document** |

Two concrete holes:

1. **No actuator.** `Ieee2030_5Adapter::execute_dispatch` constructs a `reqwest::Client` and
   discards it without issuing a request
   (`gridtokenx-aggregator-bridge/crates/aggregator-logic/src/standards/ieee2030_5.rs:50`) — it
   logs and returns `Ok(())`. It self-declares `is_simulation() == true`
   (`crates/aggregator-logic/src/dispatch/mod.rs:17`) so the VEN listener suppresses execution
   reports rather than attest dispatch that never physically happened, and `src/main.rs` warns
   loudly when the VEN uses it. The stub is honest — but it means nothing actuates.

2. **No target.** `DispatchAdapter::execute_dispatch(action, capacity_kw)`
   (`crates/aggregator-logic/src/dispatch/mod.rs:10`) carries no meter or zone parameter, and
   the gRPC adapter hardcodes `cluster_id: "default-cluster"`
   (`crates/aggregator-logic/src/dispatch/grpc_client.rs:19`). Dispatch is fleet-wide only.

Meanwhile the simulator **already has real actuation**. `DemandResponseController.schedule`
(`gridtokenx-smartmeter-simulator/backend/src/smart_meter_simulator/core/demand_response.py:95`)
sheds a `reduction_fraction` of participating load over a half-open sim-clock window, filtered
by `target_meter_types` **and** `target_zones`
(`.../core/demand_response.py:43`), and the shed feeds the same per-tick power-flow solve. It is
reachable only through the simulator's own REST API
(`.../routers/simulation_v1.py:352`), which no service calls.

The missing piece is the translation layer between them — not new actuation physics.

## 2. Decision

**Make the simulator an OpenADR 3 VEN** that polls the VTN already running in compose and
translates `DISPATCH_SETPOINT` events into `DemandResponseEvent`s.

```
freq excursion → DispatchEngine → OpenLeadrAdapter → VTN(:4031)
                                                       │ poll
                                                       ▼
                        sim VEN → DemandResponseController → meters shed load
                                                       │
                                                       ▼
                    next tick's DLMS telemetry → bridge → observed load drop
```

This closes a genuinely measurable control loop: the actuation shows up in the next tick's
readings and re-enters the bridge through the existing ingest path, so the loop is verifiable
end-to-end from telemetry alone.

### Why the VEN sits in the simulator

The simulator owns the meter fleet, the electrical model, and the shed mechanism. Putting the
VEN anywhere else means inventing a second actuation path into meters that already have one.

### OpenADR 3 is REST — no SDK dependency

OpenADR 3.x replaced the 2.0b XML/EiEvent model with a plain REST/JSON API plus OAuth2
client-credentials. The `openleadr` package on PyPI implements **2.0b only** and is not usable
here. The VEN will be a thin `httpx` client (already a backend dependency,
`backend/pyproject.toml:21`) against the VTN's `/auth/token`, `/programs`, `/events`,
`/reports`. **Confirm exact paths against the running VTN's OpenAPI before implementing** —
the compose VTN is upstream `openleadr-rs` v0.2.4 and its surface is the authority, not this
document.

## 3. Alternatives rejected

| Alternative | Why not |
| --- | --- |
| Give `Ieee2030_5Adapter` a real HTTP target | Proper IEEE 2030.5 is XML/CSIP; the existing stub is ad-hoc JSON. Wiring a target ships something half-standard that would not survive contact with a real 2030.5 client. |
| Direct REST call, bridge → simulator's `/simulation/demand-response` | Fastest, but no standards value, and it bypasses the VTN that already runs. Creates a private control protocol alongside a standard one. |
| Wait for `gridtokenx-vtn-service` (scale RFC phase 0) | The scale RFC's entire program is gated behind a new service. This plan needs only the VTN already in compose, and its VEN work is reusable against the future service unchanged. |

## 4. Phased plan

### Phase 1 — sim VEN, fleet-wide (the loop closes)

- New `backend/src/smart_meter_simulator/transport/openadr_ven.py`: OAuth2 token acquisition,
  poll `/events` filtered by program + target, dedupe by
  `(event id, modificationDateTime, interval)` — mirroring the dedupe discipline in
  `crates/aggregator-logic/src/standards/openleadr_ven.rs:229`.
- Translate a signed-kW `DISPATCH_SETPOINT` into a `DemandResponseEvent`: negative setpoint
  (shed) → `reduction_fraction` = setpoint kW ÷ current fleet load, clamped to `(0, 1]`
  (the controller rejects anything outside that range); the event interval becomes the DR
  window `[start, end)`.
- Wire into the engine lifespan with the same shape as the aggregator emitter: env-gated
  (`OPENADR_VEN_ENABLED`, `OPENADR_VTN_URL`, credentials), **default off**, background task,
  failures logged and never propagated into a tick.
- **Must filter by program/target.** The bridge runs its own VEN listener against a VTN; once
  the simulator joins, an unfiltered poll would consume events intended for the bridge. The
  bridge already warns about the self-consumption case in `src/main.rs` — the simulator must
  not reintroduce it from the other side.

### Phase 2 — execution reports back to the VTN

Report actual shed kW as an OpenADR report. The simulator already tracks `total_dr_shed_kw`
per tick, so this is a reporting transport, not new measurement. This is what makes the loop
auditable rather than open-loop, and it is the M&V leg the `is_simulation()` guard exists to
protect.

### Phase 3 — per-zone targeting (trait change)

Zones here are electrically real: derived from transformer topology, islandable, each with its
own frequency. Fleet-wide-only dispatch discards that.

- Introduce `DispatchCommand { action, capacity_kw, target: Option<DispatchTarget> }` and a
  trait method `execute(&self, cmd: &DispatchCommand)` whose **default implementation delegates
  to today's `execute_dispatch`** — so all three existing adapters and their tests compile
  untouched.
- `OpenLeadrAdapter` maps `target` onto OpenADR's native per-event `targets` field. It
  currently supports only one static `OPENLEADR_TARGET` from config
  (`crates/aggregator-logic/src/standards/openleadr.rs:130`), applied to every event.
- Sim VEN maps the target to `DemandResponseEvent(target_zones=…)` — already implemented and
  already exercised by `tests/test_demand_response.py`.

## 5. Open questions

- **Where does the zone target come from?** Per-zone dispatch requires the bridge to decide
  *which* zone is in trouble. Today `DispatchEngine::evaluate_and_dispatch`
  (`crates/aggregator-logic/src/dispatch/engine.rs:196`) triggers on a single fleet-wide
  frequency from a Kafka `GridStatusEvent`. The inputs exist — meters send `zone_code` and
  frequency (`1.1.14.7.0.255`) in every OBIS frame, and the bridge already partitions readings
  by zone — but aggregating per-zone frequency and driving dispatch from it is real work, not a
  parameter change. **This is the decision that could reshape the trait, so it is worth settling
  before phase 1 hardens.**
- **Fraction vs. absolute setpoint.** OpenADR `DISPATCH_SETPOINT` is absolute signed kW; the DR
  controller takes a fraction of load. The conversion depends on instantaneous fleet load, so
  the same event yields a different shed at different times. Acceptable for a simulator;
  worth recording as a known modelling gap if the paper cites dispatch accuracy.
- **Relationship to the scale RFC.** If `gridtokenx-vtn-service` is built, the sim VEN repoints
  by URL with no code change. Nothing here forecloses that path.

## 6. Testing

- **Sim-side pytest** against a faked VTN (httpx mock, no live server): token flow,
  event → `DemandResponseEvent` translation, dedupe across polls, program/target filtering,
  clamping of out-of-range fractions.
- **`just openadr-e2e`** (`scripts/openleadr-e2e.sh`) extended to drive the full loop: publish a
  dispatch event, assert the simulator schedules a DR event, assert the next tick's readings
  show reduced consumption.
- **Bridge-side unit tests** only if phase 3 lands — the default-delegating trait method means
  phases 1–2 change no Rust.

> There is no CI in this repo. Every gate above is manual; a green local run is the only signal.
