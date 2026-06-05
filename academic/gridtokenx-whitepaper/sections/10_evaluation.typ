= Evaluation Methodology and Reproducibility

This section defines how GridTokenX should be evaluated and distinguishes measured results from analytical capacity estimates. The current manuscript should not be read as a claim of production deployment performance unless the corresponding benchmark output, deployment configuration, and dataset are published with the paper. The open-source implementation is the reference artifact for reproducing the evaluation @gridtokenx.

== Evaluation Questions

The evaluation is organized around four research questions:

1. *Matching throughput*: Can the off-chain CDA matching engine process enough bid-ask pairs to feed the settlement layer without becoming the bottleneck?

2. *On-chain feasibility*: Do settlement, oracle, registry, and token instructions remain within Solana compute-unit and account-size limits under realistic batch sizes?

3. *Grid feasibility*: Does the grid-aware matching policy reduce physically infeasible trades relative to an unmanaged P2P market under the same load and DER assumptions?

4. *Operational resilience*: Can telemetry ingestion, replay protection, and settlement retry logic tolerate device outages, duplicate submissions, and network partitions without double-minting or double-settlement?

== Benchmark Artifacts

The repository contains the following evaluation entry points:

#table(
  columns: (1fr, 1.2fr, 1fr),
  inset: 8pt,
  align: (left, left, left),
  [*Artifact*], [*Command or Location*], [*Primary Metric*],
  [Trading engine microbenchmark], [`just benchmark`], [CDA match-cycle latency and throughput],
  [Criterion benchmark source], [`gridtokenx-trading-service/crates/trading-engine/benches/matching_benchmark.rs`], [1000x1000 order matching cost],
  [AC power-flow simulation], [`gridtokenx-smartmeter-simulator/backend/scripts/simulate_pandapower.py`], [voltage range, line loading, convergence],
  [Large telemetry load test], [`gridtokenx-smartmeter-simulator/backend/scripts/load_test_100k.py`], [effective meter-frame throughput],
)

The grid simulation uses pandapower @pandapower2018 to run AC power-flow analysis on the reference feeder model. The present repository includes an 80-bus rural low-voltage reference grid under the smart-meter simulator data directory; production studies should replace this model with utility-approved feeder topology and measured load/generation profiles.

== Matching Engine Benchmark

The trading benchmark initializes 1,000 buy orders and 1,000 sell orders with crossing prices, applies a topology snapshot that accepts all flows, and measures one full matching cycle. This isolates the matching engine from database, network, and blockchain latency. A publishable result should report:

- CPU model, core count, memory, operating system, Rust version, and compiler flags.
- Number of buy orders, sell orders, zones, and matched pairs.
- Mean, median, p95, and p99 match-cycle latency.
- Allocation count and memory footprint, if available.
- Throughput in matched pairs per second.

This benchmark is necessary but not sufficient: it shows that the off-chain matcher can produce fills, but it does not prove end-to-end settlement capacity.

=== Preliminary Local Benchmark Result

As a preliminary reproducibility check, the Criterion benchmark was executed locally with the command `just benchmark`. The run used macOS 26.5.1 on an Apple M2 CPU with 8 logical cores and 16 GB RAM, using Rust `1.95.0` and Cargo `1.95.0`. The benchmark measured the synthetic `matching cycle 1000x1000` case described above.

#table(
  columns: (1fr, auto, auto),
  inset: 8pt,
  align: (left, center, left),
  [*Metric*], [*Estimate*], [*95% confidence interval*],
  [Mean match-cycle time], [22.231 ms], [21.847--22.653 ms],
  [Median match-cycle time], [21.472 ms], [21.294--21.751 ms],
  [Standard deviation], [2.080 ms], [1.469--2.580 ms],
)

Criterion reported 7 outliers among 100 measurements and a local performance regression relative to the previous saved baseline. This result should be interpreted only as a single-machine microbenchmark of the in-memory matching engine. It does not include database access, network transport, Solana transaction construction, signature verification, RPC submission, confirmation latency, or on-chain account contention.

== On-Chain Settlement Capacity

The Trading Program supports batching up to four matched order pairs per settlement transaction. A target of 50,000 settled trades per hour corresponds to approximately 13.9 matched trades per second, or approximately 3.5 settlement transactions per second at four pairs per transaction. This is an analytical capacity target, not a measured production result.

To support a stronger claim, the paper should include a Solana localnet or devnet experiment with:

- deployed program IDs and commit hash,
- exact Solana and Anchor versions,
- transaction batch size,
- compute units consumed by `place_order`, `match_orders`, `submit_reading`, and `finalize_interval`,
- confirmation latency distribution,
- failed transaction rate and retry count,
- account contention profile by market shard.

Results should be reported in a table that separates local validator measurements from public cluster measurements because consensus, RPC, and priority-fee behavior differ materially across environments.

== Grid-Aware Simulation Protocol

Grid-aware trading should be evaluated against at least three baselines:

1. *Unmanaged P2P*: Orders are matched by price-time priority without grid capacity checks.

2. *Static tariff P2P*: Orders include fixed wheeling charges but no dynamic congestion component.

3. *GridTokenX policy*: Orders include zone distance, dynamic wheeling charges, Grid Loss Factor, and VPP capacity limits.

For each scenario, the simulator should use the same feeder topology, load profile, PV profile, battery availability, and order-arrival process. The primary metrics are peak line loading, voltage violations, curtailed energy, matched trade volume, average buyer price, average seller revenue, and average wheeling charge. Any claim such as "reduces peak zone loading by 18%" should include the dataset, number of simulation days, random seeds, baseline definition, and confidence interval.

== Reproducibility Requirements

For academic submission, the following information should accompany the paper:

- repository URL and commit hash,
- commands used to build smart contracts and services,
- benchmark logs or CSV outputs,
- simulation input datasets,
- hardware and cloud configuration,
- random seeds for load and order generation,
- license and availability status for any non-public utility data.

Without these artifacts, the results in this paper should be framed as design goals, analytical estimates, or proposed evaluation methodology rather than empirical claims.
