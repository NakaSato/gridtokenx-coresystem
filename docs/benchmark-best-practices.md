# Benchmark Best-Practices — P2P Energy Trading

Methodology reference for benchmarking the GridTokenX P2P solar energy
trading system. Two metric families must both be reported:

1. **Systems performance** — throughput, latency, compute cost (what
   [`gridtokenx-anchor/BENCHMARKS.md`](../gridtokenx-anchor/BENCHMARKS.md)
   measures today).
2. **Market & grid quality** — allocative efficiency, self-sufficiency,
   cost-per-trade (the P2P contribution; currently unmeasured).

A pure systems micro-benchmark does **not** prove a P2P-energy contribution.
Reviewers in this field expect both.

> Items are tagged by priority: **[CRIT]** fix or claims get rejected ·
> **[IMP]** important for a strong paper · **[POLISH]** rigor polish.

---

## Part A — Systems-performance hygiene

Standard OLTP/blockchain-benchmark discipline. The current results already
do warmup, n=150, CI95, percentiles, CU capture, and git+host metadata —
keep those. Gaps:

1. **[CRIT] Benchmark the real settlement instruction.** BlockBench /
   SmallBank / TPC-C are *generic* OLTP. They characterize account-model
   cost, not the CDA settlement path. Add a workload that exercises the
   actual settle-trade instruction (escrow + order nullifier + signature
   verify + trade record) so TPS/CU describe *this system*, not a proxy.
2. **[CRIT] Multi-validator, not single node.** A single
   `solana-test-validator` measures no consensus cost, yet the headline
   claim is "consensus block-time is the bottleneck." Run a 3–4 node PoA
   cluster to validate it. If infeasible, demote every claim to
   "single-node baseline" explicitly.
3. **[CRIT] Open-loop load, not only fixed concurrency.** Closed-loop
   (fixed in-flight count) couples arrival rate to completion and
   underestimates queueing. Add open-loop: fix arrival rate λ, ramp until
   tail latency / drop-rate explodes. Report **max sustainable TPS** at an
   SLA (e.g. p99 < X ms).
4. **[CRIT] Find the collapse point.** Current TPC-C sweep stops at c=40
   (29.9 TPS, still climbing). Push to saturation and past it; report peak
   TPS, the knee, and degradation beyond it. "Up to 40" reads as "limit not
   found."
5. **[IMP] Repeat the whole sweep N times → CI on TPS.** Latency has CI95
   but TPS is a single point per concurrency level. Run the sweep ≥3–5×;
   report TPS mean ± CI. One run = no error bar on the headline number.
6. **[IMP] Make sequential workloads concurrent, or label them.**
   BlockBench/SmallBank run sequentially → their ~1.6 TPS is latency-bound,
   not a throughput measure. Either run concurrent or label "latency
   micro-benchmark, TPS not a throughput figure" so 1.6 isn't misread.
7. **[IMP] Decouple execution time from confirmation.** The latency is
   block-time-dominated, not program-dominated — quantify it: report
   CU→estimated-execution-time separately from network confirmation.
8. **[POLISH] State the loop model explicitly** — open vs closed, think-time,
   ramp/cooldown — in the methodology.
9. **[POLISH] Justify warmup count.** Discarding 10 iters is fine; show a
   steady-state plot or state how the count was chosen.
10. **[POLISH] Account-contention as an independent variable.** The TPC-C
    `District.next_o_id` hotspot is a good finding — report hot vs
    partitioned-account configs side by side.

---

## Part B — P2P-energy domain metrics

What makes this an *energy* paper, not a generic systems paper.

### Workload must match grid cadence
1. **[CRIT] Settlement-window throughput, not raw TPS.** Real P2P clears in
   fixed windows (15 min / 900 s). The meaningful question: "can the chain
   settle every trade from one window before the next opens?" Report
   **trades-cleared-per-window vs window deadline**. 29.9 TPS × 900 s ≈ 26.9k
   trades/window headroom — that framing, not bare TPS.
2. **[IMP] Bursty arrival, not uniform.** Trades cluster at window close.
   Benchmark a burst (N trades dropped at once); measure drain time < window.
   Uniform load hides the real stress.
3. **[IMP] Scale in prosumers/meters, not just concurrency.** The independent
   variable reviewers want is # participants. Sweep 10→100→1000 prosumers;
   show TPS + latency + cost curves. Unify with the 80-meter telemetry-ingest
   run so both axes (meters, trades) appear together.

### Market-quality metrics (the P2P contribution)
4. **[CRIT] CDA allocative efficiency / social welfare.** The P2P thesis is
   *better matching*. Report matched-volume %, price convergence, and welfare
   vs a baseline (uniform-price auction or grid feed-in tariff). Systems
   numbers alone don't prove P2P is worth it.
5. **[IMP] Self-sufficiency / self-consumption ratio + peak shaving.**
   Standard energy-community KPIs — how much surplus is traded locally vs
   exported to the DSO. This is *why* P2P matters.
6. **[CRIT] Cost per trade — economic viability.** Convert ~21k CU/tx to a
   fee/$ at a stated lamport price. Report the fee-to-trade-value ratio. P2P
   only works if the trade fee ≪ energy value — the adoption question.

### Consortium / PoA-specific
7. **[IMP] Liveness under validator failure.** PoA consortium is a governance
   claim. Benchmark TPS/finality with 1-of-N validators down — energy infra
   is availability-critical.
8. **[CRIT] Multi-validator** (mirror of A.2). Single node ≠ consortium. At
   least 3–4 PoA nodes, or demote all consortium claims.

### Comparison baselines this field uses
9. **[IMP] Compare against ≥1 peer system.** **Hyperledger Fabric** dominates
   P2P-energy literature — most cited systems use it. Also viable: private
   EVM/Ethereum, Tendermint. Report CU/TPS/latency vs theirs; Solana-for-
   energy is novel, so the comparison sells the novelty.
10. **[IMP] vs centralized baseline.** A DB-backed market-clearing baseline
    quantifies the blockchain overhead — the honest "tax" paid for
    decentralization.

---

## Reproducibility metadata to record

Already captured: git commit, host, n, warmup, CI95, raw JSON/CSV artifacts.
Add for the P2P claims:

- **Validator topology** — node count, geo / inter-node latency.
- **Economic params** — lamport price, fee model.
- **Market config** — # orders, price distribution, buy/sell mix.
- **Grid params** — window length, meter sampling interval, # prosumers.

---

## Minimum viable for this paper

If time-boxed, do these and the contribution holds:

| From | Item |
|------|------|
| A.1  | Real settlement-tx workload |
| A.4  | Push to saturation |
| A.5  | Repeat sweep → CI on TPS |
| B.1  | Window-throughput framing |
| B.4  | CDA welfare metric |
| B.6  | Cost per trade |
| B.9  | One baseline (Fabric) |

Converts *"we benchmarked OLTP on Solana"* → *"our P2P settlement clears a
grid window within deadline at \$X/trade, N× cheaper/faster than Fabric, at
M% allocative efficiency."* That is a P2P-energy contribution, not a systems
micro-benchmark.
