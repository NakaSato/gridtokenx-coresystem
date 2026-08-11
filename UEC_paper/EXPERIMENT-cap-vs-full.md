# Experiment: 10 kWh/day cap vs settling 100% of surplus

Prepared 2026-08-11. **Not yet run** — this document is the design, the commands,
and the traps.

## Question

The paper's community month applies a 10 kWh/day sell cap per prosumer. On the
canonical run the cap bound on 305 of 360 prosumer-days and withheld 68% of the
oracle-accepted surplus from the market, certifying it as RECs instead. So every
headline number describes a market that traded a minority of the available energy.

This ablation asks what changes when the cap is lifted and **100% of the
oracle-accepted surplus is minted, settled and burned**:

- does Eq. (1) still close, with the REC term going to zero?
- does per-match compute stay flat (it should — the packet, not the quantity,
  bounds a settlement)?
- does net revenue per kWh hold, or does clearing more volume move the price?

Run A is the paper's policy, run B is the same month with the cap effectively
removed. Nothing else differs.

## Commands

```bash
cd gridtokenx-anchor
./scripts/bench-cap-vs-full.sh                  # both arms, ~2 × replay time
SKIP_RESET=1 ONLY=B ./scripts/bench-cap-vs-full.sh   # one arm, chain already up
```

Knobs: `DATASET`, `PRICE_MODEL` (default `uniform`), `ZONE_ID` (default 702),
`OUT` (default `test-results/cap-ablation`).

Outputs land in `test-results/cap-ablation/`: `run-A.json`, `run-B.json`, the two
audit logs, and `comparison.txt` from
`scripts/compare-cap-ablation.py`.

"100%" is achieved with `SELL_CAP_KWH=1000000`, not a code change: the harness
offers `min(dailySurplus, cap)` (`bench-community-month.ts:382`, `:721`), so a cap
far above any daily surplus never binds and no surplus is left for the REC path.

## Traps, in the order they will bite

1. **Each arm needs its own ledger.** The oracle enforces strictly-increasing
   per-meter timestamps, so replaying the same month onto a chain that already
   holds it makes every reading fail the monotonicity guard. Run B on a used
   ledger reports near-zero accepted readings and everything downstream is
   meaningless. The script resets between arms; `SKIP_RESET=1` hands you that
   responsibility.
2. **The zone must have a `ZoneMarket`.** Otherwise orders are accepted and
   matched but can never settle (`AccountOwnedByWrongProgram`, Custom 3007). The
   script calls `init-zones.sh` for `ZONE_ID`.
3. **Validator lifetime.** `app.sh` schedules an auto-kill after 1800 s by
   default, which would end a month replay mid-run; the script starts a bare
   `solana-test-validator` with no such timer. On Apple Silicon it also raises
   `ulimit -n`, without which the validator panics under load.
4. **Chain-clock drift.** The replay uses the dataset's historical timestamps, so
   mints are backdated and the `chain_now + 900 s` future-window guard
   (`mint_generation.rs`, Custom 6010) should not fire. If it does, the chain has
   drifted far enough to need a reset before the run.
5. **The dust floor still applies.** 0.1 kWh per prosumer-day is skipped in both
   arms, so "100%" means 100% of oracle-accepted surplus above the dust floor.
   Expect a small residue rather than an exact zero.

## Dataset caveat — the paper's month is not reproducible as-is

`test-results/datasets/` does **not** contain the fleet the paper reports
(80 meters, 12 prosumers, 30 days: 15,868.5 kWh generated, 10,386.7 kWh surplus).
What exists:

| dataset | prosumers | days | generated | surplus |
| --- | --- | --- | --- | --- |
| `scale-80m-8p-s42-30d-cap5` | 8 | 30 | 4,174.7 | 1,111.4 |
| `scale-80m-8p-s42-30d-uncapped` | 8 | 30 | 10,939.9 | 7,876.7 |
| `scale-80m-12p-s42-7d-cap5` | 12 | 7 | 1,595.2 | 395.6 |

The ablation therefore defaults to `scale-80m-8p-s42-30d-uncapped`, chosen because
its mean surplus is about 33 kWh per prosumer-day, so a 10 kWh cap binds hard and
the two arms differ sharply. Its absolute numbers will not match Table 1, and the
comparison should be reported as an ablation in its own right, not as a correction
to the canonical run. Reproducing Table 1 exactly needs the 12-prosumer month
regenerated from the simulator (`export_month_dataset.py`, seed 42).

`cap5` / `uncapped` in a dataset name refer to the **PV generation** used to build
it, not to the sell cap — the sell cap is a run-time knob.

## Fix applied while preparing this

`scripts/audit-lifecycle.ts` hardcoded the fleet in its two currency-conservation
checks — `12 * 10` seller escrow seeds and `68 * 1_000_000_000` buyer budgets —
so on any dataset that is not 12 prosumers / 68 consumers both checks failed for
reasons unrelated to conservation. They now derive from
`artifact.dataset.prosumers` and `meters - prosumers`. The 8-prosumer /
72-consumer fleet above would have tripped this immediately.

## What to report if it runs clean

For the paper, the useful line is that lifting the cap changes *volume* and the
REC term while leaving per-match compute and per-kWh economics unmoved — which is
the packet-bound claim holding under a different load. If per-kWh revenue does
move, that is a finding about the price rule, not the settlement layer, and
belongs with Table 3 rather than Table 2.
