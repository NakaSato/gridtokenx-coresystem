# Tech Debt Tracker

Running ledger of known shortcuts, deferred work, and architectural debt. Each item has an owner-
intent, a blast radius, and a trigger that says when it must be paid down.

Status legend: 🔴 blocking · 🟠 should-fix · 🟢 nice-to-have · ✅ paid down

| ID | Item | Area | Severity | Trigger to pay down | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| TD-001 | _example_ — direct DB call bypassing repository layer | trading | 🟠 | before next settlement refactor | open |
| TD-002 | Settlement settles a freshly-completed bin before late readings arrive → strands energy | aggregator | 🟢 | before onboarding intermittent/offline-buffered meters | mitigated (boundary case) |

### TD-002 — partial-bin settlement strands energy on late telemetry

`SettlementEngine::process_completed_bins` peeks any bin with `end_time <= now` and mints + evicts
it (`settlement_engine.rs:117-165`, `aggregator.rs::peek_completed_bins`). A reading whose timestamp
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

## How to use

1. Add a row when you knowingly take a shortcut. Reference the commit or PR that introduced it.
2. Severity reflects risk if left unpaid, not effort to fix.
3. The **trigger** is the condition that converts the debt from "tolerated" to "must fix now" —
   usually a feature that would compound it.
4. Move resolved items to ✅ with the paying commit; keep them for one quarter, then prune.

## Sources to mine for debt

- [`../../gridtokenx-refactor-checklist.md`](../../gridtokenx-refactor-checklist.md)
- [`../../gridtokenx-refactor-plan.md`](../../gridtokenx-refactor-plan.md)
- `cargo clippy -- -D warnings` output across services
- `// TODO` / `// FIXME` / `// HACK` markers in service code
