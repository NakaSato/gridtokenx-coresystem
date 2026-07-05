/// metrics.typ — single source of truth for benchmark figures.
/// ──────────────────────────────────────────────────────────
/// Canonical measured inputs live in `metrics`; everything derivable
/// is computed with `calc` so it cannot drift. Top-level `assert`s run
/// whenever this module is imported (or the paper compiles) and FAIL the
/// build if a derived figure no longer matches the number quoted in prose.
/// Demonstrates the foundations primitives: dictionary, calc, assert.

// ── MEASURED INPUTS (edit these; the rest follows) ────────────────────────
#let metrics = (
  num-meters: 80,          // NUM_METERS
  sim-interval-s: 15,      // SIMULATION_INTERVAL (simulated seconds)
  settle-cu: 96707,        // computeUnitsConsumed, 1 matched pair
  cu-budget: 200000,       // Solana default CU budget / instruction
  cu-tx-max: 1400000,      // Solana max CU / transaction
  total-readings: 26240,   // signature-verified readings, no loss
  match-median-ms: 32.56,  // CDA match cycle, 1000×1000, median (Criterion)
)

// ── PRICING / REVENUE SCENARIO (sec:revenue-sensitivity) ──────────────────
// Baseline inputs for the seller-net sensitivity table; FiT is an illustrative
// comparison rate (not a measured market figure — see the section's caveat).
#let pricing = (
  ps: 4.0,         // baseline sell ask ฿/kWh
  q: 10,           // matched quantity kWh
  fit-rate: 2.20,  // assumed flat feed-in tariff ฿/kWh
)

// ── DERIVED (never hand-type these) ───────────────────────────────────────
#let nominal-rate = calc.round(metrics.num-meters / metrics.sim-interval-s, digits: 2)
#let budget-pct = calc.round(metrics.settle-cu / metrics.cu-budget * 100)
#let batch-max = calc.floor(metrics.cu-tx-max / metrics.settle-cu)

// ── INVARIANTS — fail the compile on drift ────────────────────────────────
#assert(nominal-rate == 5.33, message: "nominal ingest rate drifted from 5.33 readings/s")
#assert(budget-pct == 48, message: "settlement CU is no longer ~48% of the default budget")
#assert(batch-max == 14, message: "batch-settlement upper bound drifted from 14 pairs/tx")
#assert(
  metrics.settle-cu < metrics.cu-budget,
  message: "settlement CU exceeds the per-instruction default budget",
)
