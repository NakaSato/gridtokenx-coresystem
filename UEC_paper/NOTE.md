# NOTE — UEC paper

## Hard constraint: 2 pages

`uec_main.typ` must compile to **exactly 2 pages, never more**. Any edit that adds
content has to be paid for by cutting elsewhere — trimming prose, tightening a
table, or shrinking a figure. Do not solve an overflow by relaxing margins,
font size, or leading unless the venue's template explicitly allows it.

## Build

```bash
cd UEC_paper
typst compile uec_main.typ --font-path . uec_main.pdf
```

The `--font-path .` is mandatory — Times New Roman is vendored next to the
source (`Times New Roman.ttf`, `Times New Roman Bold.ttf`), not installed
system-wide.

## Check the page count after every edit

```bash
mdls -name kMDItemNumberOfPages uec_main.pdf   # must print 2
```

Typst does not warn on overflow — it silently spills onto page 3. Treat a count
of 3 as a build failure and cut content until it is back to 2.

Last verified: 2026-08-09 — 2 pages, and **essentially full**: page 2 ends at
y≈758 of 842 pt. Anything added now must be paid for by an equivalent cut.

## Provenance of the reported figures

Verified 2026-08-09 against `gridtokenx-anchor/BENCHMARKS.md` §11 (canonical run
2026-07-07): readings, month energy, accepted surplus, 919 rejections, 1,394.7 s /
1,858×, ≈213 readings·s⁻¹, 53 TPS, 107 k CU, 15/15 assertions — all match.

Two caveats that the paper now states, and that must stay stated:

- The revenue triple (uniform 2.289650 > buy-back 2.200 > CDA 2.065325 ฿/kWh) comes
  from the **price-model sweep** (`test-results/revenue-sweep.csv`), not from the
  80-meter community-month run. It is invariant across fleet sizes, but the ranking
  **reverses** when supply is left uncapped
  (`test-results/endog-uncapped-80m.json`: uniform 1.9906 < buy-back 2.200).
- `audit-community-month.ts`, the harness that produced the 15/15 result, is **no
  longer in the repo**; only `scripts/audit-lifecycle.ts` (11 checks) survives.
  `BENCHMARKS.md`'s claim that `bench-community-month.ts` was also removed is stale
  — that file does still exist.
