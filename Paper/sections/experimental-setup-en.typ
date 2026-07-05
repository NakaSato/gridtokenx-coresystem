#import "../metrics.typ": nominal-rate

= EXPERIMENTAL SETUP <sec:experimental-setup>

This section summarizes the implementation details, the version of the artifact, the workload parameters, and the definitions of the metrics, so that the evaluation in @sec:evaluation is reproducible. We state the remaining reproducibility limitations candidly at the end of this section.

== Implementation and Artifact
All backend services are developed in Rust (Axum) on the Tokio async runtime and communicate with one another over ConnectRPC on top of mTLS, while the path that writes data to the blockchain is decoupled through NATS JetStream @natsio2024. The grid and Smart Meter simulation suite is developed in Python 3.11 @python311 (tool details are in @sec:grid-simulator). The whole system is arranged as a superproject that incorporates each service as a git submodule, which makes the version of the artifact identifiable from the commit of the superproject together with the pointer of each submodule. The experiments in this article refer to the state of the superproject at commit `4b05661`, which pins the pointers of the core services — namely Aggregator Bridge, Chain Bridge, Anchor programs, blockchain-core, and Smart Meter Simulator. The on-chain cost and throughput measurements (@sec:settlement-cost, @sec:onchain-throughput, and @sec:cu-profile) are carried out on the gridtokenx-anchor benchmark suite at commit `58cfc79`, which is an ancestor of the pointer pinned by the superproject `4b05661` and therefore lies on the same line of development.

== Topology and Endpoints
On the evaluated path, the Smart Meter Simulator sends readings into the Aggregator Bridge through the IoT gateway (HTTP) and a gRPC channel for ingest. The Aggregator Bridge then verifies the signatures and disseminates the validated readings into zone-partitioned Redis Streams, while the chain-write path is routed through the Chain Bridge using the NATS `chain.tx.*` family of subjects (e.g., `chain.tx.submit` and `chain.tx.mint`). Separating the ports and channels in this way allows the ingest path to scale independently of the settlement path.

== Workload Parameters
The workload in the evaluation is defined by 80 Smart Meters (`NUM_METERS=80`) that send readings every 15 seconds of simulated time (`SIMULATION_INTERVAL=15`), following the default of the simulation suite. A transmission cycle of every 15 seconds of simulated time corresponds to a time compression of approximately 60× relative to the 15-minute (900-second) window of the real meters' transmission cycle. Here we define a "reading" — the unit used to measure throughput — to mean one meter reading signed with Ed25519 that has passed signature verification and been disseminated into a Redis Stream at the Aggregator Bridge, not a matched trading order or an on-chain settlement transaction. The main workload parameters are summarized in @tbl:workload.

#figure(
  caption: [Workload parameters for the telemetry-ingest evaluation.],
  text(size: 8pt)[
    #show math.equation: set text(size: 8pt)
    // env-var names render as monospace code (override the template's serif-italic inline raw)
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal")
    #table(
    columns: (auto, auto, 1fr),
    inset: (x: 4pt, y: 3pt),
    align: (left + horizon, left + horizon, left + horizon),
    table.header([Parameter], [Value], [Meaning]),
    [`NUM_METERS`], [80], [Number of Smart Meters in the simulation],
    [`SIMULATION_INTERVAL`], [15 s], [Reading transmission cycle in simulated time],
    [Time compression], [≈ 60×], [Relative to the real 900 s window],
    [Nominal ingest rate], [#nominal-rate readings/s], [80 ÷ 15 in simulated time],
    [Run duration], [≈ 27 min], [Wall-clock time of one run],
    [Total readings], [26,240], [Signature verification succeeded, no loss],
    )
  ],
) <tbl:workload>

== Metrics
The primary metric of the ingest-path evaluation is the ingest rate, under two definitions: the design-time rate in simulated time (nominal), equal to $80 div 15 = 5.33$ readings per second, and the rate measured from wall-clock time, which is higher because the simulator's transmission cycle is accelerated beyond the 15-second interval of simulated time, together with the cumulative number of successfully verified readings and the data-loss ratio. The detailed measurement results are in @sec:ingest-throughput.

== Reproducibility Limitations
The long-running ingest-path experiment in @sec:ingest-throughput is a single real run, while the step-load experiment in @sec:ingest-saturation is repeated 5 times per fleet size and reports the mean together with the standard deviation on the recorded Apple M2 (8 cores, 16 GiB memory) machine. The remaining reproducibility limitation is that the workload is generated from a single sender client (parallel senders have not yet been tested), so the reported ingest-rate figures are a lower bound of the ingest path rather than the ceiling of its maximum capacity, and the on-chain settlement-path measurement is still limited to the compute-unit cost per instruction, without yet covering end-to-end latency and throughput. The next experiment should therefore add parallel senders to find the true ceiling, record the validator configuration, and extend the measurement to cover the on-chain settlement path end-to-end (see @sec:discussion_limitations).
