== Fleet-Scale Solver Throughput and Live On-chain Mint Validation <sec:scale-onchain-validation>

_Solver cost is tracked as the fleet grows orders of magnitude, and computed surplus is confirmed reaching a real on-chain mint; a single validator runs ~0.5 tx/s (global-write-bound by design), yet ~450 settlements fit per 900 s window — about 10× tested demand._

Beyond the ingest-path measurements (@sec:ingest-throughput, @sec:ingest-saturation) and the on-chain cost/throughput results (@sec:settlement-cost, @sec:onchain-throughput), we ran two further experiments to probe the simulator's capacity envelope along orthogonal axes: (a) solver and reading-generation compute cost as fleet size grows by orders of magnitude, with no network egress at all, and (b) confirmation that the surplus energy the simulator computes actually reaches a real on-chain mint through every layer of the stack. Both experiments are single exploratory runs, not repeated-trial benchmarks with reported mean and standard deviation as in @sec:ingest-saturation, and should be read as design-indicative figures pending repeated measurement, not final reference numbers.

=== Solver Throughput at Fleet Scale
The first experiment drives `SimulationEngine.tick()` directly, bypassing the network path entirely (no Aggregator Bridge, no blockchain), to isolate the cost of per-meter device-model generation and the power-flow solve on the 80-bus reference topology at fleet sizes of 10,000, 50,000, and 100,000 meters. Rooftop-PV assignment is randomized per meter at a 10% ratio (rather than pinning one meter per bus as in the original default) via the `SOLAR_PROSUMER_RATIO` parameter. Results are summarized in @tbl:fleet-scale-en.

#figure(
  caption: [Per-tick solver wall-clock cost vs. fleet size (single exploratory run, 4 ticks/case, no network egress).],
  text(size: 7pt)[
    #table(
      columns: (auto, auto, auto, auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, center + horizon, center + horizon, center + horizon, center + horizon),
      table.header([*Meters*], [*PV share*], [*median tick*], [*p95 tick*], [*max tick*]),
      [10,000], [9.90%], [16.5 s], [17.7 s], [17.7 s],
      [50,000], [9.81%], [97.6 s], [107.8 s], [107.8 s],
      [100,000], [9.97%], [230.4 s], [397.5 s], [397.5 s],
    )
  ],
) <tbl:fleet-scale-en>

The measured PV share converges toward the configured 10% target as fleet size grows, consistent with the law of large numbers over the per-meter random draw, and confirms that the `SOLAR_PROSUMER_RATIO`/`GRID_CONSUMER_RATIO`/`HYBRID_PROSUMER_RATIO` parameters now actually take effect for topology-backed fleets (prior to the fix, the split was hardcoded to 70/20/10 and these parameters were silently ignored). Per-tick wall-clock cost scales mildly super-linearly with fleet size — the 100,000-meter case takes roughly 14× the 10,000-meter case's tick time for a 10× larger fleet — indicating that per-meter reading generation (single-threaded CPU-bound work dispatched via `asyncio.to_thread`) is the bottleneck, not the power-flow solve, whose topology size is fixed regardless of meter count.

=== Live On-chain Mint Proof
The second experiment probes the opposite axis: a small fleet (100 meters) with the full network path enabled — meter-owner onboarding through the IAM Service (register → verify → login, with on-chain PDA registration), Ed25519 device-key registration in the Aggregator Bridge's device registry, mTLS- and AES-256-GCM-encrypted signed reading ingest every tick, and a real on-chain mint transaction signed and submitted by Chain Bridge once a settlement window closes. The run targets the same single solana-test-validator used in @sec:onchain-throughput.

Results from a 100-meter, 5-tick run confirm the full path is consistent end to end: owner onboarding for all 100 meters completed in roughly 11 s; every ingested reading passed signature verification and was disseminated into its zone Redis Stream; and — the key proof point — *140 real on-chain mint transactions across 20 unique meters* were observed, each carrying a verifiable Solana transaction signature and slot number (for example, a 0.08568 kWh mint with signature `3NbmxvqEKRLfM2yEYJLNy7axVcibwBXTzVbDAPAhdbNaN643ZPdVJa3mAvnxuqK6Y2dZ64BRdKK29bM1ttyjV7kw` at slot 1424). This closes the gap the first experiment deliberately leaves open — that experiment drives `tick()` directly without calling `start()`, so it never touches the Aggregator Bridge or the chain at all — by demonstrating that the net-surplus figures the simulator computes agree with what is actually minted on-chain.

This experiment is deliberately small in scale: IAM onboarding is one HTTP round-trip per meter owner, and each mint is a genuinely signed Solana transaction per settlement window. Running the 10,000–100,000-meter fleets from the solver-throughput experiment with the full network path enabled is out of scope for this work and is left for future work that scales both IAM onboarding throughput and the test validator's capacity accordingly (see @sec:discussion_limitations).

=== Fleet-Scale Live Mint Throughput
A third experiment closes part of the future-work gap the previous one leaves open: driving the *full* network path (IAM onboarding, signed encrypted ingest, settlement, and Chain Bridge minting) at fleet sizes in the thousands rather than 100, using a dedicated harness against the same single solana-test-validator. Each meter's one net-surplus reading is backdated into an already-closed 15-minute settlement window so the sweep evicts it without waiting for real time to pass. Results are summarized in @tbl:fleet-mint-en; as with the two experiments above, these are single exploratory runs, not repeated trials.

#figure(
  caption: [Fleet-scale live on-chain mint throughput (single exploratory runs).],
  text(size: 7pt)[
    #table(
      columns: (auto, auto, auto, auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, center + horizon, center + horizon, center + horizon, center + horizon),
      table.header([*Fleet*], [*Minted*], [*Overall TPS*], [*Steady TPS (10 s median)*], [*Peak TPS (10 s)*]),
      [1,000], [1,000 / 1,000], [29.3], [—], [—],
      [10,000], [10,000 / 10,000#footnote[9,921 minted directly within the watch window; the remaining 79 landed later via the durable mint outbox's retry — see the wallet-link incident below.]], [18.4], [37.7], [123.2],
      [25,000 (tuned)], [25,000 / 25,000], [23.2], [14.6], [193.4],
    )
  ],
) <tbl:fleet-mint-en>

At an untuned baseline, a 25,000-meter burst overloads Chain Bridge's mint-consumer queue: envelopes queue past the aggregator's 55-second staleness cap faster than the fixed-concurrency consumer (8 in-flight confirmations) can drain them, so rejected envelopes are republished, deepening the queue further — goodput decayed from 16.7 to 3.7 mints/s in a positive-feedback congestion collapse before the run was stopped manually (2,559 of 25,000 minted). Raising the mint-consumer concurrency (8 → 64), skipping a redundant pre-flight simulation, and lengthening the aggregator's reply-wait budget (30 s → 120 s) eliminated the collapse: the tuned 25,000-meter row above cleared with zero stale-rejects and zero republish amplification (versus 65,117 stale-rejects and a 22,528-entry outbox re-published every tick at baseline).

The 10,000-meter run also surfaced a genuine operational bug worth reporting on its own terms: a subset of onboarded users' wallet-link writes were lost when the IAM service itself was OOM-killed during the highest-concurrency onboarding bursts. The root cause was that IAM's request-metrics middleware labeled Prometheus counters by the literal request path rather than the route template, so each `PATCH /wallets/{id}` call — issued once per onboarded user to set a primary wallet — permanently added a new label series; resident memory therefore grew with *cumulative onboard count*, not concurrency, until the container's memory limit was exceeded. No surplus was permanently lost — the affected meters were flagged "no wallet registered, kept for retry" and the durable mint outbox re-minted them into their original settlement window once the wallet links were repaired (the 79-meter tail in @tbl:fleet-mint-en) — but the incident is a concrete illustration of why per-request metrics must be labeled by route template, not literal path, under any workload with per-entity path parameters.

=== On-chain Telemetry Write Scaling by Meter Count <sec:meter-scale-en>
A fourth experiment isolates the on-chain layer of the telemetry path — the oracle program's `submit_meter_reading` instruction alone, bypassing IAM and the Aggregator Bridge entirely — to answer a question the mint experiments above leave open: does on-chain state-write capacity degrade as the per-meter PDA account set grows into the hundreds of thousands? The harness builds client-signed transactions against a cached blockhash, submits them `skipPreflight` through a windowed open loop capped at 3,000 in-flight transactions, and confirms via bulk `getSignatureStatuses` polling (256 signatures per call at a 1.5 s cadence, so reported latencies are quantised by ±1.5 s), at fleet sizes of 10,000, 50,000, 100,000, 150,000, and 200,000 meters, two epochs each: the first epoch creates each meter's PDA (init, heavier compute), the second overwrites existing state (steady). All scales run back-to-back on the same single solana-test-validator without a ledger reset in between, so the 200,000-meter case starts against an existing set of over 310,000 meter PDAs and the validator ends the sweep holding 510,000 meter PDAs from this experiment alone; the experiment totals 1,020,000 transactions. Results are summarized in @tbl:meter-scale-en; as with the other experiments in this section, each scale is a single exploratory run.

#figure(
  caption: [On-chain telemetry write throughput vs. meter count (single exploratory run per scale; latency quantised ±1.5 s by the status-poll cadence).],
  text(size: 7pt)[
    #table(
      columns: (auto, auto, auto, auto, auto, auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon,) + (center + horizon,) * 6,
      table.header([*Meters*], [*ok/total*], [*TPS (init)*], [*TPS (steady)*], [*p50 ms*], [*p95 ms*], [*CU steady (med)*]),
      [10,000], [19,908 / 20,000], [439.2], [429.1], [1,546], [2,354], [15,025],
      [50,000], [99,524 / 100,000], [319.8], [243.1], [1,868], [3,064], [13,525],
      [100,000], [199,048 / 200,000], [409.6], [455.5], [1,553], [2,346], [15,060],
      [150,000], [298,572 / 300,000], [449.4], [426.2], [1,586], [2,402], [13,560],
      [200,000], [398,096 / 400,000], [438.5], [443.2], [1,582], [2,391], [13,560],
    )
  ],
) <tbl:meter-scale-en>

The headline finding is flat throughput across scale: steady-state TPS stays in the 426–455 band from 10,000 through 200,000 meters (the 243 at 50,000 is a transient validator stall that does not recur at larger sizes), p50 latency holds at roughly 1.5–1.9 s, and per-transaction compute cost is constant (steady median 13,525–15,060 CU, far below the 200,000 CU per-instruction budget) independent of the accumulated account count. This empirically confirms the per-meter PDA state design — one `MeterState` account per meter, with the hot path never writing the global `OracleData` account — keeps reading writes parallelizable under Sealevel, and that the remaining serialization point is the single gateway fee-payer wallet (write-locked on every transaction), not account-set size. Every failed transaction (0.46–0.48% per scale) is a deterministic logical rejection by the oracle's own anomaly detector — a small fraction of the synthetic readings violate the production-to-consumption ratio cap, checked by integer cross-multiplication (`AnomalousReading`) — with not a single send rejection, queue overflow, or blockhash expiry at any scale. The global aggregate counters on `OracleData` remain zero throughout by design: the hot path treats that account as read-only, and reconciling fleet totals is the job of the periodic administrative `aggregate_readings` instruction. The key limitation is that all results come from a single validator and a single submitting wallet, so the measured ceiling is a property of this configuration; spreading load across multiple gateway fee-payers and measuring on a multi-node cluster remain future work (see @sec:discussion_limitations).

=== What "Network Limitation" Decomposes Into <sec:network-limits>
It is tempting to summarize a distributed energy system by a single "network throughput" number, but every ceiling this system actually meets is a scheduling or serialization limit rather than a bandwidth one — no measurement anywhere in this work is bounded by the rate at which bytes move over a link. The apparent network limit decomposes into three distinct walls, at three layers, each with its own fix and its own evidence, summarized in @tbl:network-walls.

#figure(
  caption: [The three throughput walls of the system, none of them bandwidth. Each is a serialization or scheduling limit at a different layer, with a distinct escape and distinct measured evidence. The middle wall is the one the settlement design actually targets.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6pt)
    #table(
      columns: (auto, 1fr, 1fr),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (left + horizon, left + horizon, left + horizon),
      table.header([wall], [what it caps], [evidence]),
      [slot cadence], [any op needing one consensus round-trip → ~2 TPS per serial chain], [~485 ms/slot ⇒ 2.06 TPS write vs 1,454 TPS RPC read],
      [account write-lock], [same-slot txs sharing a mutable account serialize], [`zone_market` read-only: 1→3 settles/slot (~2.7×)],
      [ingest event loop], [one sender process saturates its own CPU scheduler], [~200 tx/s per client; ~400/s bridge; loss ≤ 0.48%],
    )
  ],
) <tbl:network-walls>

The first wall is the slot cadence of the consensus layer. A slot on the tested configuration takes roughly 485 milliseconds, and any operation that must wait for one consensus round-trip before the next can proceed is floored by that interval regardless of how little compute it uses. The clearest evidence is a controlled contrast: a trivial no-op instruction that still requires a slot to confirm runs at a flat 2.06 transactions per second, identical to a compute-heavy instruction on the same path, because both are paying for the slot and not for the work — whereas a pure account read served over RPC without any consensus round-trip runs at about 1,454 transactions per second on the same machine. The three-order-of-magnitude gap between them is the price of consensus, and it means latency-bound operations are block-time-bound, not program-bound. This is a platform property of any Solana-compatible network and is not something the programs in this system can tune.

The second wall is the one the settlement design genuinely targets, and it is account write-lock serialization rather than anything on the wire. Solana's parallel scheduler co-schedules two transactions only if their write sets are disjoint; two transactions that mutate the same account serialize no matter how much network or compute capacity is idle. The settlement path was, in an earlier form, bound by exactly this: every same-zone settlement took a write lock on the shared `zone_market` account, capping the zone at roughly one settlement per slot. Splitting the mutable committed-flow counter onto a separate `ZoneCapacity` account and leaving `zone_market` read-only on the common path (the design already described in the settlement model) lifts that to about three settlements per slot — a measured factor of roughly 2.7, achieved purely by changing which account is locked, with no change to compute. The same effect appears at the order layer: order entry, which contends on shared book state, is measured at about 180 transactions per second at a ten-thousand-order scale, whereas meter ingest at the same scale reaches about 462 because each reading writes only its own per-meter account. And the discovery path, which shares no hot lock, scales cleanly from 7.87 to 74.25 transactions per second as concurrency rises from 5 to 40 — a 9.4-fold gain climbing monotonically with no plateau, which is the positive control proving that when the shared lock is removed the transport does not bind. The lesson is that adding validators or bandwidth does not raise the settlement ceiling; making the hot account read-only does. Sharding helps only across *different* locked accounts, so every same-zone settlement contending on one `zone_market` PDA serializes regardless of how many shards exist elsewhere.

The third wall is off-chain, at the ingest client. A single sender process feeding the Aggregator Bridge saturates at roughly 200 transactions per second, and the limit is its own event loop and CPU scheduler rather than signature-verification cost or link bandwidth — pushing more parallel senders past the core count reduces throughput through contention rather than raising it. The bridge itself verifies at roughly twice that rate. Under sustained fleet load the consequence is not error but a small, purely transport-level loss: over a three-thousand-transaction window the delivery loss stays at or below 0.48% (and is frequently zero), with p95 latency under about 3.1 seconds and not a single on-chain error, the losses being expiries and rejections at the sender rather than faults in the chain. This is the same lower-bound-of-a-single-client caveat noted for the saturation measurement in @sec:ingest-saturation.

Taken together, these three walls say something specific about how to scale the system, and it is not "add bandwidth." Latency-bound operations are floored by the slot and are the platform's to improve; the settlement ceiling is raised by reducing what each settlement write-locks, which is a program-design lever the system already pulls; and ingest is widened by adding sender processes up to the core count, not by faster links. None of the three is a bandwidth problem, which is why none of the measurements in this work reports one. The single-validator, single-wallet caveat of @sec:meter-scale-en still applies throughout — a multi-node cluster would introduce the consensus-layer transport costs (leader rotation, gossip fan-out, fork choice) that a single-node localnet never exercises, and quantifying those remains future work (@sec:discussion_limitations).
