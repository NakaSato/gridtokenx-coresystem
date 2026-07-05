#import "@preview/lilaq:0.6.0" as lq
#import "@preview/zero:0.6.1": format-table, set-group
#import "../metrics.typ": metrics

// Okabe-Ito colorblind-safe palette — shared across every data plot in this section
// for a consistent, publication-clean look (no harsh primary blue/red).
#let c-blue = rgb("#0072B2")       // primary series (throughput, measured, CU)
#let c-orange = rgb("#E69F00")     // secondary series (loss)
#let c-vermillion = rgb("#D55E00") // emphasis / budget threshold
#let c-gray = rgb("#999999")       // reference / ideal lines

== Ingest Loss and Single-Sender Cost Under Step Load <sec:ingest-saturation>
To evaluate the loss behavior of the ingest path beyond the design rate of 5.33 readings per second from @sec:ingest-throughput, and to characterize the cost of a single full-rate sender, we apply a stepwise load ramp with meter-fleet sizes of 40, 80, 160, 320, and 640 meters, where each step runs for 60 seconds and is repeated 5 times to report the mean and standard deviation. In each run the simulator sends Ed25519-signed readings continuously at maximum rate (no delay between send rounds). The primary metric, measured at the HTTP boundary, is the fraction of requests that the Aggregator Bridge accepts, signature-verifies, and disseminates successfully into the Redis Stream (HTTP 200), where throughput = number of successful readings ÷ elapsed time and loss = number of failed requests ÷ total requests. The results are summarized in @tbl:ingest-ramp and the trend is plotted in @fig:ingest-ramp. The experiment runs on an Apple M2 machine (8 cores, 16 GiB memory).

#figure(
  caption: [Ingest throughput and loss vs. meter-fleet size (mean ± sd over 5 runs, 60 s each).],
  text(size: 7pt)[
    // zero: decimal-align the throughput (mantissa ± uncertainty) and loss (exponent) columns.
    #show math.equation: set text(size: 7pt) // zero emits math; keep it at cell size
    #show table: format-table(auto, auto, auto)
    #table(
      columns: (auto, auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (center + horizon, center + horizon, center + horizon),
      table.header([*meters (count)*], [*throughput (readings/s)*], [*loss (max)*]),
      [40],  [134.4+-9.2],   [0],
      [80],  [72.8+-6.9],    [2.6e-4],
      [160], [88.4+-15.0],   [2.2e-4],
      [320], [115.0+-19.8],  [0],
      [640], [148.9+-25.6],  [1.0e-4],
    )
  ],
) <tbl:ingest-ramp>

#figure(
  text(size: 8pt)[
    #lq.diagram(
      width: 7cm, height: 4.4cm,
      xscale: "log",
      xaxis: (ticks: ((40, [40]), (80, [80]), (160, [160]), (320, [320]), (640, [640]))),
      xlabel: [meters (count)],
      ylabel: [throughput (readings/s)],
      ylim: (0, 180),
      legend: (position: top + left),
      // primary axis: throughput (left)
      // mean ± sd shown as a filled band (cleaner than error bars at this density)
      lq.fill-between(
        (40, 80, 160, 320, 640),
        (125.2, 65.9, 73.4, 95.2, 123.3),   // mean − sd
        y2: (143.6, 79.7, 103.4, 134.8, 174.5), // mean + sd
        fill: c-blue.transparentize(82%), stroke: none, z-index: 0,
      ),
      lq.plot(
        (40, 80, 160, 320, 640),
        (134.4, 72.8, 88.4, 115.0, 148.9),
        mark: "o", color: c-blue, label: [throughput],
      ),
      // secondary axis: request loss in percent (right)
      lq.axis(
        kind: "y", position: right, lim: (0, 0.04),
        label: [loss (%)],
        lq.plot(
          (40, 80, 160, 320, 640),
          (0, 0.026, 0.022, 0, 0.010),
          mark: "s", color: c-orange, label: [loss],
        ),
      ),
    )
  ],
  caption: [Request loss (right axis) and single-sender throughput (left axis, mean ± sd) vs. meter-fleet size. The headline result is loss: it stays ≤ 0.03% across the whole tested range. Throughput is non-monotonic and single-client sender-bound — the cost of one full-rate sender, a lower bound, not a service-saturation curve.],
) <fig:ingest-ramp>

The measurements yield two main observations. First, the loss ratio stays near zero across all fleet sizes, with the maximum measured value being approximately 2.6 × 10#super[−4] (about 0.03%) at the 80-meter size, and several runs exhibit no loss at all. This indicates that the ingest path maintains a near-zero loss ratio (≤ 0.03%) up to a load of 640 meters. Second, the measured ingest throughput does not increase monotonically with the number of meters but fluctuates in the range of approximately 73–149 readings per second (mean), with a relatively high standard deviation (up to about 26 readings per second at 640 meters). Because this experiment generates load from a single sender client that operates asynchronously and sends per-meter readings sequentially per tick, this fluctuation and non-monotonicity likely reflect sender-side limits (such as the cost of building and signing readings, and single-client processing) together with the cadence of asynchronous dissemination into Redis, rather than saturation of the ingest service. We do not draw a definitive conclusion about the cause of this pattern from the available data.

From these results, the highest measured mean rate (mean over 5 runs at the 640-meter fleet) is approximately 149 readings per second, which is several times higher than the design rate of 5.33 readings per second and occurs at the largest fleet size tested (640 meters). However, the measured rate does not increase monotonically with the number of meters (the mean at 80 meters is lower than at 40 meters), so we do not conclude whether or not the ingest path reaches saturation from this dataset. Nevertheless, because the load is generated from a single sender client that transmits sequentially per meter per tick, this figure is a lower bound, reflecting that the Aggregator Bridge can support one full-rate sender client with near-zero loss, rather than the true capacity ceiling of the ingest path. Measuring the true ceiling requires multiple parallel senders and isolating the sender-side cost (such as onboarding and signing) from the cost of the ingest service, which remains future work. We also note that the rates in this ramp experiment (73–149 readings per second) are higher than the roughly 16 readings per second wall-clock rate of a single continuous run in @sec:ingest-throughput, because the ramp experiment sends with no delay between rounds (max rate) to find the scaling envelope, whereas the continuous run ties the send cadence to the 15-second simulated-time interval.

== Off-chain Matching Throughput <sec:matching-throughput>
Beyond the ingest path, we measure the order-matching cost of the Continuous Double Auction (CDA) matching engine in the off-chain layer with a micro-benchmark (Criterion) that calls the matching function for one match cycle over an order book of 1,000 buy orders and 1,000 sell orders (2,000 orders total), where every buy order price is set higher than every sell order price so that matching is full, yielding a maximum of approximately 1,000 order pairs per cycle. The experiment runs on the same machine (Apple M2, 8 cores, 16 GiB memory) and collects 100 samples after the warm-up period. The results are summarized in @tbl:matching-tput.

#figure(
  caption: [In-memory CDA matching throughput (one match cycle over 1,000 bids × 1,000 asks, 100 samples).],
  text(size: 7pt)[
    #table(
      columns: (auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, center + horizon),
      table.header([*Metric*], [*Value*]),
      [Time per 1,000 × 1,000 match cycle (median)], [#metrics.match-median-ms ms],
      [95% confidence interval], [32.28–32.75 ms],
      [Order processing rate (≈)], [6.1 × 10#super[4] orders/s],
      [Order-pair matching rate (≈)], [3.1 × 10#super[4] pairs/s],
    )
  ],
) <tbl:matching-tput>

The matching engine processes one full cycle of orders on both sides in a median time of 32.56 milliseconds (95% confidence interval approximately 32.28–32.75 milliseconds), which corresponds to a processing rate of approximately 6.1 × 10#super[4] orders per second, or about 3.1 × 10#super[4] matched order pairs per second on a single thread. This value measures only in-memory matching and does not include the cost of on-chain transaction settlement, persistence, or network communication; it is therefore an upper bound on the matching rate cleanly separated from the settlement cost. This result indicates that in the layered architecture, off-chain matching is not the system bottleneck compared to the on-chain settlement cost in @sec:settlement-cost. We note that single-cycle 1,000 × 1,000 matching is a synthetic workload to measure per-cycle cost, not a steady-state rate under a real order stream with diverse price and zone distributions, which is the next step.

== On-chain Settlement Cost <sec:settlement-cost>
Beyond the ingest path, we directly measure the on-chain processing cost of settlement by reporting the compute units (CU) actually consumed by the off-chain match settlement instruction, read from the `computeUnitsConsumed` value of the confirmed transaction in the escrow settlement test on solana-test-validator 3.1.10 (Agave client). This value is a deterministic on-chain cost metric independent of the validator hardware, unlike latency on a local test network, which does not reflect the design's target network. The result is summarized in @tbl:settle-cu.

#figure(
  caption: [Measured compute-unit cost of the settlement instruction (1 matched order pair).],
  text(size: 7pt)[
    // zero: group-format + align the compute-unit figure (comma sep to match prose "96,707").
    #set-group(separator: ",")
    #show math.equation: set text(size: 7pt)
    #show table: format-table(none, auto)
    #table(
      columns: (auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, center + horizon),
      table.header([*instruction*], [*compute units*]),
      [settlement per 1 order pair], [#metrics.settle-cu],
    )
  ],
) <tbl:settle-cu>

The value of 96,707 CU per settlement of one order pair#footnote[The compute cost depends on the token-leg transfer pattern of the transaction. The reported value is from one escrow settlement test variant; the path with a classic-SPL to Token-2022 exchange leg measures around 103k CU, and batch settlement using Token-2022 on both legs measures around 80–92k CU. The figure of 96,707 is therefore specific to the measured variant, not a universal constant.] compared with the per-instruction default compute budget of 200,000 CU and the maximum per-transaction ceiling of 1,400,000 CU indicates that each settlement uses approximately 48% of the default budget. We note that although the maximum per-transaction compute ceiling could in theory support around 14 pairs per transaction, the binding constraint is not compute but the transaction packet size of 1,232 bytes, which squeezes the number of pairs per transaction below the ceiling of 4 pairs that the `batch_settle_offchain_match` program allows (see @sec:tx-structure). Therefore, reducing the per-pair cost via batch settlement requires changing the way signatures are packed, not merely relying on the remaining compute budget. The 48% per-instruction cost level remains consistent with the design of having the blockchain serve as a low-compute settlement layer per @sec:system-architecture.

== On-chain Transaction Throughput <sec:onchain-throughput>
Beyond the per-instruction compute cost in @sec:settlement-cost, we measure the throughput of on-chain transaction processing using standard OLTP workloads ported to Solana's account model, namely BlockBench (a SIGMOD 2017-style microbenchmark together with YCSB), SmallBank, and TPC-C, augmented with a measurement of the real settlement path (settle_offchain_match). All run on a single solana-test-validator (single-node; a permissioned network governing participation via PoA) on an Apple M2 machine (8 cores) at commit `58cfc79` of gridtokenx-anchor, where latency is wall-clock time of the client→confirmed path and compute units are read from the `computeUnitsConsumed` of confirmed transactions. The sequential OLTP workload results are summarized in @tbl:oltp-bench and the TPC-C concurrency sweep results are summarized in @tbl:tpc-sweep.

#figure(
  caption: [Standard OLTP workloads ported to the account model (sequential, n = 150). TPS here is latency-bound by the single-client submit loop, not a throughput ceiling; `ycsb_read` is an RPC account fetch with no consensus round-trip.],
  text(size: 7pt)[
    #table(
      columns: (auto, auto, auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, center + horizon, center + horizon, center + horizon),
      table.header([*workload · op*], [*mean ms*], [*TPS*], [*CU/tx*]),
      [BlockBench · `do_nothing`], [719.95], [1.39], [648],
      [BlockBench · `cpu_heavy_sort`], [590.83], [1.69], [9,645],
      [BlockBench · `ycsb_read` (RPC)], [4.29], [233.18], [—],
      [SmallBank · `SendPayment`], [604.63], [1.65], [5,963],
      [SmallBank · `Amalgamate`], [631.62], [1.58], [5,936],
    )
  ],
) <tbl:oltp-bench>

#figure(
  caption: [TPC-C concurrency sweep (TX = 500, 50% NewOrder / 50% Payment), 100% success at every level. Throughput from concurrent in-flight submission; CU/tx is flat across load.],
  text(size: 7pt)[
    #table(
      columns: (auto, auto, auto, auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (center + horizon,) * 5,
      table.header([*concurrency*], [*TPS*], [*mean ms*], [*p95 ms*], [*CU/tx (mean)*]),
      [5], [8.67], [575.00], [726.10], [21,263],
      [10], [14.50], [679.34], [879.95], [20,633],
      [20], [21.87], [856.74], [1,656.15], [21,269],
      [40], [29.90], [1,057.79], [1,707.00], [21,508],
    )
  ],
) <tbl:tpc-sweep>

#figure(
  text(size: 8pt)[
    #lq.diagram(
      width: 6.5cm, height: 4cm,
      xscale: "log",
      xaxis: (ticks: ((5, [5]), (10, [10]), (20, [20]), (40, [40]))),
      xlabel: [concurrency (in-flight tx)],
      ylabel: [TPS (settled/s)],
      ylim: (0, 75),
      legend: (position: top + left),
      // shade the throughput shortfall (measured vs linear-ideal) — the sublinear gap
      lq.fill-between((5, 10, 20, 40), (8.67, 14.50, 21.87, 29.90), y2: (8.67, 17.34, 34.68, 69.36),
        fill: c-gray.transparentize(85%), stroke: none, z-index: 0),
      lq.plot((5, 10, 20, 40), (8.67, 17.34, 34.68, 69.36), mark: none, color: c-gray, label: [linear (ideal)]),
      lq.plot((5, 10, 20, 40), (8.67, 14.50, 21.87, 29.90), mark: "o", color: c-blue, label: [measured]),
    )
  ],
  caption: [TPC-C throughput vs. concurrency on the single-node validator. Measured TPS scales sublinearly — 8× concurrency yields only 3.45× throughput — diverging from the linear-ideal reference, with the saturation knee between concurrency 10 and 20.],
) <fig:tpc-tps>

The most important figure for this system is the throughput of the real settlement path, not that of a generic proxy. When measuring the `batch_settle_offchain_match` path with an open-loop submission sweep (pre-building transactions, then firing them concurrently according to the concurrency level and re-firing dropped transactions until confirmed), we obtain a rate of only ~0.5 TPS that stays flat at every concurrency level (this figure comes from a single recorded run, unlike the TPC-C/OLTP set whose raw results were committed as an artifact, so it should be interpreted as a design-indicative value pending re-measurement) (conc 5 → 0.51, conc 10 → 0.58 TPS; goodput 100%, no on-chain reverts, CU around 86–89k). It also does not scale with the number of concurrently submitted transactions; even distributing settlement across all 16 shards yields a near-identical figure (0.57–0.59 TPS), because the bottleneck is not the shard but the central set of accounts that every settlement must always write, namely the accumulator account `total_settled_thbg` and the fee/wheeling/loss collector accounts. Settlement is therefore global-write-bound by design; sharding can parallelize only order submission, which uses per-entity PDAs, not the reconciliation of settlement.

In the TPC-C sweep, the compute units per transaction stay flat at around 21,000 CU at every concurrency level, indicating that the throughput bottleneck is the block production time (block time around 400–600 milliseconds) together with the serialization of central account writes, not the on-chain processing. For this reason, compute units per transaction (@sec:settlement-cost) is a cost metric independent of workload and machine, whereas TPS is a figure that depends on the single validator used for testing. The sweep also exhibits sublinear scaling (concurrency 5 → 40, an 8-fold increase, yields only a 3.45-fold increase in TPS) and a saturation knee between concurrency 10 and 20 where the latency variance and p95 increase markedly, as shown against the linear reference line in @fig:tpc-tps.

Compared with the 900-second clearing window, even the real settlement rate of ~0.5 TPS still supports around 450 settlements per window. The 80-meter workload places at most one order per meter per window, so it generates at most $floor(80 slash 2) = 40$ matched pairs per window; the 450-settlement capacity is therefore roughly $11 times$ that demand. More generally, a single-validator settlement budget of about 450 pairs per window covers a fleet of up to roughly 900 meters at one order per meter per window before a second validator or a wider clearing window is required, which bounds the deployment size this design serves on a single node. The proxy ceiling of 29.9 TPS is equivalent to around 2.69 × 10#super[4] transactions per window. However, all results come from a single validator and should therefore be interpreted under four limitations. First, measurements on a single validator do not reflect the consensus cost (PoH together with Tower BFT) of a multi-node permissioned network, which is the basis for the observation that block time is the bottleneck. Second, BlockBench, SmallBank, and TPC-C are generic proxies, not energy workloads, so the TPS of the real settlement path is significantly lower than the proxy figures. Third, the sequential path in @tbl:oltp-bench at ~1.4–1.7 TPS is latency-bound, not a throughput ceiling. And fourth, the TPC-C sweep TPS figures are single-point values per concurrency level, reporting confidence intervals only for latency (latency CI95) and not yet repeated over multiple runs to report a confidence interval for TPS. Multi-node open-loop measurement with repetition to find peak TPS at an SLA level is the next step (see @sec:discussion_limitations).

== Per-instruction Compute-unit Profile <sec:cu-profile>
Beyond the cost of the main settlement path in @sec:settlement-cost, we measure the per-instruction compute cost of every on-chain program in the real execution path, to confirm by measurement that the on-chain compute load is kept thin by design. All values are read from the transactions' `computeUnitsConsumed`, measured in-process with LiteSVM over a default-feature build at commit `58cfc79` of gridtokenx-anchor, except for the settlement instruction `settle_offchain_match`, which is measured on a live validator (@sec:settlement-cost). Because compute units are deterministic, they are comparable between the two methods. The result is summarized in @fig:cu-profile.

#figure(
  caption: [Measured per-instruction compute-unit cost across the on-chain programs (LiteSVM `computeUnitsConsumed`, default-feature build; `settle_offchain_match` measured on a live validator per @sec:settlement-cost), sorted by cost. Only the signature-verifying settlement path approaches half the 200,000 CU per-instruction budget (dashed); every other instruction stays well below — the measured signature of a thin settlement layer.],
  text(size: 6.5pt)[
    #show raw: set text(font: ("Courier New", "Courier"), size: 5.5pt)
    #let names = ([`update_meter_reading`], [`record_settlement_sharded`], [`burn_tokens`], [`aggregate_readings`], [`trigger_market_clearing`], [`create_sell_order`], [`match_orders`], [`update_erc_limits`], [`submit_meter_reading`], [`mint_to_wallet`], [`register_meter`], [`swap_grx_for_thbg`], [`deposit_escrow`], [`settle_offchain_match`])
    #let cu = (3899, 5370, 6537, 8362, 8390, 11508, 11746, 13283, 13376, 13700, 20104, 21488, 27658, 96707)
    #lq.diagram(
      width: 7.2cm, height: 5.4cm,
      xlabel: [compute units (CU)], xlim: (0, 205000),
      yaxis: (ticks: range(14).zip(names)),
      ylim: (-0.8, 13.8),
      lq.hbar(cu, range(14), fill: c-blue.lighten(55%), stroke: 0.5pt + c-blue),
      lq.vlines(200000, stroke: (paint: c-vermillion, dash: "dashed", thickness: 0.7pt), label: [200k budget]),
    )
  ],
) <fig:cu-profile>

From @fig:cu-profile, every instruction except the signature-verifying settlement path (`settle_offchain_match`) uses no more than approximately 28k CU, or about 14% of the 200k CU default budget, with the high-frequency paths at the lowest levels, namely `update_meter_reading` (3.9k) and `record_settlement_sharded` (5.4k), consistent with the design of having per-entity PDA accounts on the hot path not write-lock central accounts. This result confirms by actual measurement (not estimation) that heavy processing work — such as data-format validation, evaluation of grid-stability conditions, and queuing of buy/sell orders — is moved to the Backend layer first, while the Smart Contract enforces only the minimal conditions verifiable on-chain (account ownership, Ed25519 signatures, order nullifier, and escrow state), thereby serving as a low-compute settlement and audit layer as designed.

On the I/O and storage side, the architecture sends high-frequency meter data through the Aggregator Bridge for screening first, then records only the event log of transactions necessary for retrospective auditing onto the chain (see @fig:telemetry-dissemination). Quantitative measurement of record volume, retention policy, and storage cost remains future work.
