#!/usr/bin/env python3
"""Aggregate bench-ingest.sh CSV → per-step mean±sd + saturation knee.

Usage: scripts/bench-ingest-summary.py bench-ingest-results.csv

Reports, for each meter-fleet size: mean throughput (readings/s) ± sd over the
repeats, and mean loss fraction. The "knee" is the largest fleet whose throughput
is still within 5% of the running max — beyond it the bridge stops scaling, which
is the saturation point review item #1 asks for.
"""
from __future__ import annotations

import csv
import statistics
import sys
from collections import defaultdict


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)

    rows = defaultdict(list)  # meters -> [(throughput, loss), ...]
    skipped = 0
    with open(sys.argv[1], newline="") as fh:
        for row in csv.DictReader(filter(lambda l: not l.startswith("#"), fh)):
            # Skipped/failed steps are written as NA by bench-ingest.sh — exclude
            # them from the aggregates rather than crashing on float("NA").
            try:
                thr, loss = float(row["throughput_rps"]), float(row["loss_frac"])
            except ValueError:
                skipped += 1
                continue
            rows[int(row["meters"])].append((thr, loss))

    print(f"{'meters':>7} {'n':>3} {'thru_mean':>10} {'thru_sd':>9} "
          f"{'loss_mean':>10} {'loss_max':>9}")
    print("-" * 52)

    stats = []
    for m in sorted(rows):
        thr = [t for t, _ in rows[m]]
        loss = [l for _, l in rows[m]]
        tm = statistics.mean(thr)
        tsd = statistics.stdev(thr) if len(thr) > 1 else 0.0
        stats.append((m, tm))
        print(f"{m:>7} {len(thr):>3} {tm:>10.2f} {tsd:>9.2f} "
              f"{statistics.mean(loss):>10.5f} {max(loss):>9.5f}")

    if stats:
        peak = max(tm for _, tm in stats)
        knee = max((m for m, tm in stats if tm >= 0.95 * peak), default=None)
        print("-" * 52)
        print(f"peak throughput ~{peak:.1f} readings/s; "
              f"saturation knee at ~{knee} meters "
              f"(largest fleet within 5% of peak)")
    if skipped:
        print(f"note: {skipped} skipped/failed step row(s) (NA) excluded from aggregates")


if __name__ == "__main__":
    main()
