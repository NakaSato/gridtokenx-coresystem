#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge, shapes
#import "@preview/cetz:0.5.2"
#import "@preview/chronos:0.3.0"

= SYSTEM DESIGN AND IMPLEMENTATION <sec:system-architecture>

== Architecture Overview
The system architecture is designed to support the simulation of Peer-to-Peer energy trading. This work presents a microgrid model that divides the data path into the Smart Meter, Aggregator Bridge, Trading Service, Anchor Smart Contract Program, Settlement Engine, and Frontend Dashboard layers. Energy generation and consumption data are produced by the Smart Meter Simulator and then sent into the Aggregator Bridge to be screened before being converted into transaction instructions for the Anchor program on a permissioned Solana-compatible network. The decomposition of the system into off-chain and on-chain domains, together with the primary data paths and the trust-boundary crossing point, is summarized in @fig:system-architecture.

#figure(
  text(size: 5.5pt)[
    #let blob(pos, label, tint: gray, ..args) = node(pos, align(center, label),
      width: 4.6cm, fill: tint.lighten(75%), stroke: 0.6pt + tint.darken(15%),
      corner-radius: 2.5pt, inset: 3pt, ..args)
    #diagram(
      spacing: (4mm, 6mm),
      edge-stroke: 0.5pt + rgb("#777"),
      mark-scale: 60%,
      {
        let blue = rgb("#5b7aa8")
        let orange = rgb("#c77d3c")
        let green = rgb("#3c8c5a")
        let purple = rgb("#7a5b9e")
        let gray = rgb("#888")
        blob((0, 0), [*Smart Meter Simulator* \ AMI · DLMS/COSEM · Ed25519], tint: blue)
        blob((0, 1), [*Aggregator Bridge* \ verify Ed25519 · Redis · 15-min window], tint: orange)
        blob((0, 2), [*Trading Service* — CDA matching], tint: blue)
        node((1.35, 2), align(center)[*IAM*], width: 1.3cm, fill: gray.lighten(75%), stroke: 0.6pt + gray.darken(15%), corner-radius: 2.5pt, inset: 3pt)
        blob((0, 3), [*Chain Bridge* \ sole Solana RPC · NATS · gRPC · mTLS], tint: purple)
        blob((0, 4), [*Anchor programs* \ registry · trading · oracle \ energy-token · governance · treasury], tint: green)
        node(enclose: ((0, 0), (1.35, 2)), align(top + left, text(5pt, weight: "bold", fill: orange.darken(10%))[Off-chain domain — verify & match]), stroke: (paint: orange, dash: "dashed", thickness: 0.7pt), fill: orange.lighten(94%), inset: 9pt)
        node(enclose: ((0, 4),), align(top + left, text(5pt, weight: "bold", fill: green.darken(10%))[On-chain domain — settle & audit]), stroke: (paint: green, dash: "dashed", thickness: 0.7pt), fill: green.lighten(94%), inset: 9pt)
        edge((0, 0), (0, 1), "-|>", label: text(4.5pt)[signed readings])
        edge((0, 1), (0, 2), "-|>", label: text(4.5pt)[validated])
        edge((0, 2), (0, 3), "-|>", label: text(4.5pt)[matched pair])
        edge((0, 3), (0, 4), "-|>", label: text(4.5pt)[`chain.tx.*` / gRPC])
        edge((1.35, 2), (0, 2), "<|-|>")
      },
    )
  ],
  caption: [System architecture and the off-chain/on-chain trust boundary. The off-chain domain (orange, dashed) verifies Ed25519-signed meter telemetry, aggregates it, and matches orders via CDA; the on-chain domain (green, dashed) settles and audits the verified pairs. Chain Bridge is the sole crossing between the two — the only service touching Solana RPC, writing via NATS `chain.tx.*` and reading via gRPC over mTLS.],
) <fig:system-architecture>

This decomposition ensures that electrical-engineering validation and access control occur before transactions are recorded, while the Anchor program acts as a verifiable rule-enforcement layer that records state for retrospective auditing. The Settlement Engine, in turn, manages signed transactions, tracks outcomes from the transaction signature, and reads the event log to bring state back for display on the Frontend.


== Backend Services
The Backend layer acts as the intermediary between the Smart Meter Simulator (see @sec:grid-simulator), the Aggregator Bridge, and the Smart Contract. It is responsible for collecting data, validating correctness, queuing transactions, and dispatching instructions to the blockchain only after the data has passed the grid-stability conditions. The design adopts a Microservice approach to split the workload into smaller sub-workloads, allowing the system to scale only the parts with high request volume and to limit the impact when any single service fails. Details of the inter-service communication channels (ConnectRPC over mTLS and NATS JetStream) and the associated trust assumptions are described in @sec:threat-model. The main components of the Backend layer comprise:
- IAM Service: manages identity, on-chain data access rights, and user roles such as Prosumer, Consumer, and Operator.
- Aggregator Bridge: receives electricity generation and consumption data from the Smart Meter, validating the data format, reference time, device identifier, and energy values before forwarding them to the analysis stage.
- Trading Service: validates and matches energy trade orders together with grid-stability conditions such as remaining energy quantity, network constraints, and Smart Meter connection status.
- Chain Bridge: the sole intermediary that dispatches instructions to the Solana Program and tracks results from the transaction signature or event log; no other service calls Solana RPC directly.
- Notification Service: sends notifications, such as Email and Alerts, when a trade order or settlement status changes.

This separation of services helps the system better support large volumes of real-time Smart Meter data, since the data-ingestion service can scale its instance count without affecting the transaction-validation service or the blockchain-connection service. In addition, the Backend layer serves as the security control point before transactions are recorded to the Smart Contract, so that the system does not rely on the blockchain alone but integrates electrical-engineering validation with user access control.

== Grid and Meter Simulation <sec:grid-simulator>

The Grid Modeling is designed to simulate complex electrical systems, Distributed Energy Resources (DERs), and the operation of a Virtual Power Plant (VPP), thereby enabling highly accurate simulation of Advanced Metering Infrastructure (AMI) and grid management. The core of the simulation system integrates Physics-validated State Estimation in real time and Optimal Power Flow (OPF) using Pandapower, which enables the system to generate deterministic meter data for large electrical grids.

#figure(
  image("../picture/grid_bus_network.png", width: 100%),
  caption: [Grid bus network topology used by the simulator.],
) <fig:grid-bus-network>

The Grid Simulator is developed with Python 3.11 @python311 to simulate the electricity-consumption behavior of a Distribution Grid. It uses the Network Topology format from GridLAB-D GLM files @chassin2008gridlabd and converts it into a grid model consisting of bus, line, load, and photovoltaic units, as shown in @fig:grid-bus-network. The main tools used include FastAPI @ramirez2026fastapi, NetworkX @hagberg2008networkx for representing the topology structure, pvlib @anderson2023pvlib for simulating photovoltaic generation, and pandapower @thurner2018pandapower for computing power flow.

The simulation process operates in discrete time-steps, where each round consists of two stages: generating readings at the meter level (see @sec:smart-meter-simulator), followed by solving the network state at the grid level (see @sec:grid-simulation). In addition to synthetic readings, the system can also replay real telemetry data from CSV files and associate the data with a bus through the meter registry, thereby supporting hybrid simulation between measured data and synthetic data. The correctness of the simulator is verified through a test suite covering topology loading and meter-to-bus mapping.

=== Smart Meter Simulator <sec:smart-meter-simulator>
For each bus in the topology, the system generates a meter population according to the proportions of user types, where each meter (SmartMeter) is composed of modular sub-device models, namely the Load, the Solar (photovoltaic) panel when installed, and an optional Battery Energy Storage System (BESS). Electricity-consumption behavior is simulated with a voltage-dependent ZIP load model, in which the real power drawn from the network depends on the per-unit voltage according to the equation

$ P(V) = P_"base" (Z dot V^2 + I dot V + P), quad Z + I + P = 1 $ <eq:zip-load>

where the Z (impedance) component varies with $V^2$, the I (current) component varies with $V$, and the P (power) component is constant. The meters in this evaluation set the impedance fraction at 0.20 (`ZIP_IMPEDANCE_FRACTION=0.20`) and clamp the voltage into the range $[0, 1.5]$ per unit before computation. The generation from the photovoltaic panels is computed with pvlib @anderson2023pvlib using the Ineichen clear-sky model together with the PVWatts model for direct-current power, then derated by a weather derate factor — for example, cloudy multiplied by 0.42 and partly cloudy multiplied by 0.72. If pvlib is unavailable, the system falls back to a functional generation profile as a backup.

To make the simulation deterministic, each meter draws noise from its own dedicated stream by seeding its random number generator from the XOR between the system-wide seed and the SHA-256 digest of the meter identifier, so that adding or removing a single meter does not shift the readings of other meters. The result per round is an energy reading record (EnergyReading) that holds the energy produced, the energy consumed, the surplus energy, and the deficit energy as non-negative kWh values, together with the interval length of that round. Before export, each meter has a unique Ed25519 identity (per-meter key) generated deterministically from the SHA-256 of `secret:meter_id`, and signs a canonical string of the form `device_id:kwh:timestamp_ms`, exported as a base58 signature, allowing the Aggregator Bridge to verify the provenance of each reading point-by-point without keeping the meters' secret keys centrally.

=== Grid Simulation <sec:grid-simulation>
In each time tick, once the readings of all meters have been collected, the system computes the net power injection of each bus from the difference between generation and consumption, then solves the power flow to update the network state, namely the per-unit voltage of each bus, the line flow, the power loss, and the line utilization. The main solver uses pandapower @thurner2018pandapower with a backward/forward sweep (BFSW), which is an accurate AC power flow solver for radial distribution networks; and when pandapower is unavailable or the computation does not converge (non-convergence), the system falls back to an approximate DistFlow solver as a backup so that the simulation can continue.

In addition to solving the basic power flow, the grid simulation layer also simulates voltage-control mechanisms and abnormal events of the distribution network, namely the volt-watt and volt-VAR response of inverters, on-load tap changer (OLTC) adjustment, fault injection at a line, bus, or transformer, and tie-switch operation to transfer load, so that the dataset sent to the Aggregator Bridge reflects the physical behavior of the network under a variety of operating and abnormal conditions, rather than merely independently randomized energy values. That said, the above grid-physics capabilities (volt-VAR, OLTC, fault injection, and tie-switch) are part of the simulation suite but are not yet used as variables in the evaluation reported in this article, which measures only the ingest rate of signed readings, the on-chain settlement cost, and the matching rate (see @sec:evaluation). Evaluating the impact of these grid-stability conditions on matching and settlement is therefore left as future work.

To conform to industry standards and to certify data provenance, the Aggregator Bridge receives high-frequency real-time meter data and disseminates it through zone-partitioned Redis Streams for dynamic monitoring of network state, while aggregating readings into 15-minute time windows for use in the assessment of generation capacity and dispatch in the Backend layer. The meter data format follows the DLMS/COSEM standard (IEC 62056), decoding the binary payload portion with AES-256-GCM and re-publishing it in JSON form. In addition, the system guarantees cryptographic non-repudiation by verifying asymmetric Ed25519 cryptographic signatures, both for individual readings and in batches, before admitting data into the system. That said, in the current prototype there is not yet a path to construct an on-chain Settlement Attestation directly from the metering layer, which is an avenue left open for future work. The data-dissemination path of the Aggregator Bridge is summarized in @fig:telemetry-dissemination.

#figure(
  text(size: 5.5pt)[
    #let blob(pos, label, tint: gray, ..args) = node(pos, align(center, label),
      width: 2.3cm, fill: tint.lighten(72%), stroke: 0.5pt + tint.darken(15%),
      corner-radius: 2.5pt, inset: 3pt, ..args)
    #diagram(
      spacing: (2.5mm, 7mm),
      edge-stroke: 0.5pt + rgb("#777"),
      mark-scale: 60%,
      {
        let blue = rgb("#5b7aa8")
        let orange = rgb("#c77d3c")
        let green = rgb("#3c8c5a")
        // meters → bridge → three dissemination sinks (cylinders) → consumers
        blob((1, 0), [*Smart Meters (AMI)* \ Ed25519-signed · DLMS/COSEM], tint: blue)
        blob((1, 1), [*Aggregator Bridge* \ verify Ed25519 · decrypt AES-256-GCM], tint: orange)
        blob((0, 2), [Zone Redis Streams `events:zone_0..n`], tint: blue, shape: shapes.cylinder)
        blob((1, 2), [InfluxDB v2 history (async)], tint: green, shape: shapes.cylinder)
        blob((2, 2), [Window bins `(meter_id, window_start_ms)`], tint: orange, shape: shapes.cylinder)
        blob((0, 3), [Trading (CDA) · grid-state monitoring], tint: blue)
        blob((2, 3), [Dispatch · mint (energy-token)], tint: green)
        edge((1, 0), (1, 1), "-|>", label: text(4.5pt, fill: rgb("#777"))[signed readings])
        edge((1, 1), (0, 2), "-|>")
        edge((1, 1), (1, 2), "-|>")
        edge((1, 1), (2, 2), "-|>")
        edge((0, 2), (0, 3), "-|>")
        edge((2, 2), (2, 3), "-|>")
      },
    )
  ],
  caption: [Aggregator Bridge telemetry dissemination: verified readings fan out to zone-partitioned Redis Streams (real-time), an InfluxDB history sink (async, fire-and-forget), and 15-min aggregation windows keyed by `(meter_id, window_start_ms)`. Each sink sits above the consumer it feeds; the InfluxDB history sink is terminal.],
) <fig:telemetry-dissemination>

== Consortium Network <sec:consortium-network>
The blockchain network in this system is designed as a Consortium Network under the assumption of Proof of Authority (PoA) participation governance, as described in @sec:settlement-model; this section therefore focuses primarily on the details of the network design and its governance. The design ensures that block validators are entities that have a duty to verify, or have obtained consent from, the DSO — for example, a Load Aggregator, a regulatory body, or an authorized organization. The main reason for choosing PoA is network governance that is easier to control than public networks such as Solana Mainnet or Ethereum, and its suitability for regulatory-compliance requirements and cost predictability in experiments or deployments in energy systems that must estimate transaction costs in advance @joshi2021poa @androulaki2018hyperledger. The important point to emphasize is that PoA here is a governance and admission-control layer, not a replacement for the Layer 1 consensus mechanism of the Solana-compatible network, which still relies on Proof of History (PoH) together with Tower BFT for ordering and announcing block finality, as described in @sec:settlement-model.

Permission and governance policies are enforced through the on-chain governance program, which covers three main mechanisms. The first mechanism is governing the primary authorized entity (the PoA authority) through a two-step handover, where propose_authority_change lets the current authority set a pending authority together with an expiry time, and approve_authority_change must be called by the pending authority itself to accept the transfer — so that authority cannot be handed to an unconsenting or erroneous account, and only one pending change request is allowed at a time. The second mechanism is controlling the allow-list of Aggregators authorized to sign readings, via admit_aggregator and revoke_aggregator. The third mechanism is DAO voting via create_proposal, cast_vote, and execute_proposal for adjusting the economic parameters of each zone (zone_config), namely the incentive multiplier, wheeling charge, loss factor, and maintenance mode.

The voting uses weighting by the cumulative generation of meters (stake-by-generation), where a voter's weight is computed as $w = op("max")(100, "total generation" / 1000)$ — that is, every 1,000 kWh of cumulative generation is equivalent to one weight unit, with a minimum of 100 so that small participants still have a voice. Double-voting is prevented using a PDA vote record account per (proposal, voter) pair, one account per vote. When the voting period ends, execute_proposal tallies the result automatically: a proposal Passes only if the total votes reach the minimum quorum threshold (min_quorum_votes set in poa_config) and the votes in favor exceed the votes against; otherwise it is Rejected, thereby preventing parameter changes by too few voters.

The difference from the Solana public mainnet is that this network is not open to external validators joining permissionlessly, and it can define permission policies, program upgrades, and data retention according to the project's requirements. However, the execution layer still references the Solana Virtual Machine architecture and the Sealevel parallel runtime so that transactions not using the same account can be processed in parallel. The slot time near 400 ms and the compute budget mentioned in this article are design targets referenced from the Solana documentation, not measured results of the permissioned network. The separation of roles between the PoA governance layer (admission control) and the Layer 1 consensus layer — which still relies on PoH for time ordering and Tower BFT for voting and announcing finality — is shown in @fig:poa-consensus @yakovenkoSolanaWhitepaper.

#figure(
  text(size: 6.5pt)[
    #let blue = rgb("#2f6fb0")
    #let green = rgb("#3c8c5a")
    #let orange = rgb("#c97a26")
    #diagram(
      spacing: (6pt, 11pt),
      node-stroke: 0.6pt,
      {
        // Governance layer (PoA): admission control over the validator set
        node((1, 0), align(center)[*PoA Governance Authority* \ admission control \ admit / revoke validator],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + blue, fill: rgb("#eef3fb"))
        node((1, 1), align(center)[*Authorized Validator Set* \ $V_1, V_2, ..., V_n$ \ (permissioned)],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + blue, fill: rgb("#eef3fb"))
        edge((1, 0), (1, 1), "-|>", stroke: 0.6pt + blue, label: text(5.5pt, fill: blue)[admits])

        // Layer 1 consensus pipeline (unchanged Solana mechanism)
        node((0, 2), align(center)[*Leader slot* \ PoH ordering \ (verifiable clock)],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + green, fill: rgb("#e8f5ec"))
        node((1, 2), align(center)[*Tower BFT* \ stake-weighted vote \ (supermajority)],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + green, fill: rgb("#e8f5ec"))
        node((2, 2), align(center)[*Finality* \ block committed \ settlement tx durable],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + orange, fill: rgb("#fbf0e6"))
        edge((1, 1), (0, 2), "-|>", stroke: 0.6pt + green, label: text(5.5pt, fill: green)[propose])
        edge((0, 2), (1, 2), "-|>", stroke: 0.6pt + green)
        edge((1, 2), (2, 2), "-|>", stroke: 0.6pt + orange)
      },
    )
  ],
  caption: [Separation of concerns in the consortium network (illustrative): the PoA layer governs admission control over an authorized validator set, while Layer 1 consensus is unchanged — PoH provides verifiable time ordering and Tower BFT provides stake-weighted voting and finality. Roles, not measured throughput.],
) <fig:poa-consensus>

At this network level, at least five items must be defined before real deployment, namely the number of validators and the entities owning the nodes, the method of binding identity to a validator key, the policy for adding or removing validators, the process for upgrading programs or the genesis/configuration, and the acceptable fault model. This article therefore treats the PoA Solana-compatible network as an architectural assumption of the simulation system, not as a conclusion that Solana's public-network consensus has been modified.

== Smart Contract Programs <sec:smart-contract-programs>
The Smart Contract is divided into several programs by responsibility, namely registry, trading, oracle, energy-token, governance, and treasury, as well as programs for performance benchmarking (blockbench and tpc-benchmark), developed with the Anchor Framework to systematically define account validation, instruction handlers, and the event log. The registry program has register_user and register_meter for registering users and Smart Meters. The trading program has create_sell_order and create_buy_order (as well as submit_limit_order and submit_market_order) for submitting sell and buy energy orders, match_orders and clear_auction for matching the trade orders proposed by the Backend, and settle_offchain_match and execute_atomic_settlement for settling transactions as an atomic settlement, where settle_offchain_match verifies the Ed25519 signatures of both buyer and seller and uses an order nullifier to prevent replay. The energy-token program has mint_generation and mint_to_wallet for creating energy tokens that must be co-signed by the REC certifying authority (Renewable Energy Certificate), where mint_generation uses the key (meter_id, settlement window) to guarantee idempotency per time window, and burn_tokens for burning energy tokens through SPL instructions. In addition, the oracle program has submit_meter_reading for receiving readings from the AMI, trigger_market_clearing for setting the boundary of the 15-minute time window (900 seconds), and aggregate_readings for aggregating the counters of readings that pass and fail validation. The timeline of the aggregation window and market clearing is shown in @fig:clearing-window. The governance program acts as a PoA control layer for issuing and revoking Renewable Energy Certificates (REC), governing authority permissions, managing the aggregator allow-list, and DAO voting (the account structure and control-layer roles are described in @sec:governance-control-plane; the network-governance details are in the Consortium Network section). The treasury program manages staking of GRX tokens, reward payouts, and maintaining the peg of the THBC stablecoin through instructions such as stake_grx, unstake_grx, claim_rewards, swap_grx_for_thbc, redeem_thbc_for_grx, and record_settlement, which is called via Cross-Program Invocation (CPI) from the trading program. The blockbench and tpc-benchmark programs are used to run standard workloads, namely the BlockBench microbenchmark, YCSB, SmallBank, and TPC-C, for performance evaluation on the Solana-compatible network @anchorDocs @splTokenDocs. The on-chain program IDs of the six core programs, declared with `declare_id!`, are summarized in @tbl:program-ids.

#figure(
  caption: [On-chain program identities (Anchor `declare_id!`) of the six core programs on the Solana-compatible consortium network. These deterministic addresses pin the deployed artifact for reproducibility.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6.5pt)
    #table(
      columns: (auto, 1fr),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, left + horizon),
      table.header([Program], [Program ID (`declare_id!`)]),
      [registry], [`FcSd5x4X1nzJMKLZC4tMZXnQ1ipLrGsEfeoH8N4mvJX7`],
      [trading], [`CnWDEUhTvSixeLSyViWgAnnu9YouBAYVGcrrFm1s9WcX`],
      [oracle], [`64Vgos61STZ8pW9NnHi2iGtXMTQr7NqBoMorK6Zg8RJU`],
      [energy-token], [`6FZKcVKCLFSNLMxypFJGU4K14xUBnxNW9VAuKGhmqjGX`],
      [governance], [`FokVuBSPXP11aeL7VZWd8n8aVAhWqVpyPZETToSxdvTS`],
      [treasury], [`FfxSQYKUmx9NGdCC9TDPmZSYjWYE1h4ruu3JatzHN5Tn`],
    )
  ],
) <tbl:program-ids>

The account structure uses Program Derived Addresses (PDA) to separate the system state into sub-accounts keyed by specific seeds, such as registry and user account, meter account, market and market_shard, order and trade record, escrow, order nullifier for replay prevention, oracle_data, and mint authority (gen_mint, thbc_mint). Using PDAs allows the program to verify the ownership and deterministic address of an account without relying on the private key of each state account. Resource-intensive work — such as complex price computation, matching large order books, or grid-stability analysis — is therefore offloaded to the Backend and the Aggregator Bridge before the verified results are submitted to the Smart Contract, so as to stay within the compute constraints of a transaction @solanaPdaDocs @solanaDocs. The order-matching mechanism in the Trading Service uses a Continuous Double Auction (CDA) algorithm with price-time priority that partitions the order book by zone and accounts for energy-flow constraints (wheeling and loss) before sending the matched order pairs for atomic settlement on the Smart Contract. The pricing and fee formulas are described in @sec:pricing-model. The relationships among the six programs are of two kinds: Cross-Program Invocations (CPI) that write state, and control-plane reads in which one program reads another program's account to determine operation rights without invoking a CPI, as summarized in @fig:program-cpi.

#figure(
  text(size: 6.5pt)[
    #show raw: set text(size: 5.5pt)
    #let cp = rgb("#2f6fb0")
    #let wr = rgb("#c97a26")
    #let sv = rgb("#3c8c5a")
    #diagram(
      spacing: (12pt, 15pt),
      node-stroke: 0.6pt,
      {
        node((0, 0), align(center)[*oracle* \ `submit_meter_reading`],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + sv, fill: rgb("#e8f5ec"))
        node((1, 0), align(center)[*governance* \ PoA control plane],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + cp, fill: rgb("#eef3fb"))
        node((2, 0), align(center)[*trading* \ `settle_offchain_match`],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + wr, fill: rgb("#fbf0e6"))
        node((0, 1), align(center)[*energy-token* \ `mint_generation`],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + sv, fill: rgb("#e8f5ec"))
        node((1, 1), align(center)[*registry* \ users · meters · validators],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + sv, fill: rgb("#e8f5ec"))
        node((2, 1), align(center)[*treasury* \ `record_settlement` · peg],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + sv, fill: rgb("#e8f5ec"))

        edge((0, 0), (1, 0), "-|>", stroke: (paint: cp, dash: "dashed", thickness: 0.6pt),
          label: text(5pt, fill: cp)[read `AggregatorEntry`])
        edge((2, 0), (1, 0), "-|>", stroke: (paint: cp, dash: "dashed", thickness: 0.6pt),
          label: text(5pt, fill: cp)[read maintenance / ERC])
        edge((1, 0), (1, 1), "-|>", stroke: 0.6pt + wr,
          label: text(5pt, fill: wr)[CPI `mark_erc_claimed`])
        edge((1, 1), (0, 1), "-|>", stroke: 0.6pt + wr,
          label: text(5pt, fill: wr)[CPI airdrop mint])
        edge((2, 0), (2, 1), "-|>", stroke: 0.6pt + wr,
          label: text(5pt, fill: wr)[CPI `record_settlement`])
      },
    )
  ],
  caption: [Inter-program relationships among the six Anchor programs. Solid arrows are Cross-Program Invocations that write state (governance→registry on ERC issue, registry→energy-token on airdrop, trading→treasury on settlement). Dashed arrows are control-plane reads with no CPI: trading reads `governance` for the maintenance gate and ERC validity, and oracle validates an admitted-aggregator entry before accepting a reading. Governance (blue) is the policy source; trading (orange) initiates on-chain settlement.],
) <fig:program-cpi>

#figure(
  text(size: 6pt)[
    #show raw: set text(size: 5.5pt)
    #let off = rgb("#5b7aa8")
    #let on = rgb("#3c8c5a")
    #cetz.canvas(length: 1cm, {
      import cetz.draw: *
      // shaded 15-minute aggregation window
      rect((0, -0.08), (6, 0.08), stroke: none, fill: off.lighten(82%))
      line((0, 0), (6.7, 0), mark: (end: ">"), stroke: 0.7pt)
      // window boundaries
      line((0, -0.16), (0, 0.16), stroke: 0.7pt + off)
      line((6, -0.16), (6, 0.16), stroke: 0.7pt + on)
      content((0, -0.42), text(6pt)[$t = 0$])
      content((6, -0.42), text(6pt)[$t = 900$ s])
      // incoming signed readings within the window
      for i in (0.5, 1.3, 2.1, 2.9, 3.7, 4.5, 5.3) {
        line((i, 0), (i, 0.32), stroke: 0.5pt + off)
      }
      content((3, 0.66), text(6pt, fill: off)[signed readings · `submit_meter_reading`])
      content((6.35, 0.34), text(6pt, fill: on)[close])
      // post-window pipeline, centered under the axis
      content((3, -1.05), text(6pt, fill: on)[window closes → `aggregate_readings` → `trigger_market_clearing` → settle])
    })
  ],
  caption: [Market-clearing timeline: signed meter readings ingest continuously over the 15-minute (900 s) aggregation window; at window close the oracle aggregates readings, triggers clearing, and the matched pair is settled on-chain.],
) <fig:clearing-window>

=== Trading: On-chain Order Lifecycle and Escrow <sec:trading-program>
The trading program manages the lifecycle of trade orders and the on-chain escrow accounts, complementing the settlement path in @sec:settlement-model. Users create orders via create_sell_order and create_buy_order (as well as submit_limit_order and submit_market_order), which create a per-order PDA Order account bound to the owner, with the order expiry (expires_at) set to 24 hours (86,400 seconds) from the creation time. A sell order must reference an ERC certificate that has not yet expired before it can be created, consistent with the REC governance in @sec:governance-control-plane. Before entering the market, the user deposits tokens into the escrow account via deposit_escrow and withdraws the unused portion via withdraw_escrow, where the escrow account is an SPL token account under a PDA signed by the market_authority.

Order matching has two complementary paths. The first path is the off-chain matching engine (trading-engine) that runs CDA with price-time priority over the whole zone's order book at high throughput (see @sec:cda-matching and the measured rate in @sec:matching-throughput). The second path is the on-chain match_orders instruction that verifies and records each matched pair, touching only the two Order accounts and the zone_market, then writing a trade record without moving tokens, hence with a low compute cost (see @fig:cu-profile). The cancel_order instruction removes an order still pending in the book.

Market-level accounts are split into per-zone zone_market accounts that store order book depth, transmission capacity, and committed_flow, separated from the central Market account, so that order submission and the enforcement of cross-zone flow caps can run in parallel under the Sealevel model (see @sec:sealevel-sharding). Once an order pair has been matched, it is sent for atomic settlement via settle_offchain_match according to the settlement model in @sec:settlement-model.

=== Governance Program: On-chain PoA Control Plane <sec:governance-control-plane>
The governance program acts as a Proof of Authority control plane on-chain, designed as a single program that consolidates 20 instructions divided by function into five subsystems (19 main instructions, together with one statistics-query instruction get_governance_stats). The key architectural point is that governance does not operate in isolation but is the source of truth from which other on-chain programs read state to determine their own behavior; that is, governance records the "policy" while trading and oracle are the ones that "enforce" that policy at the boundary of their own program. The five subsystems comprise:
- Authority system: initialize_governance creates the initial singleton account, and authority transfer is done in two steps, propose_authority_change → approve_authority_change, where the recipient must sign themselves, together with cancel_authority_change and a 48-hour expiry. There is no single-step authority-transfer path (further described in @sec:consortium-network).
- Config gates: update_governance_config (enabling/disabling the ERC check and transfers), update_erc_limits, set_maintenance_mode (the system-wide stop switch), update_authority_info, and set_oracle_authority. Every instruction must be signed by the authority.
- ERC certificates: issue_erc validates against the policy in GovernanceConfig then invokes a Cross-Program Invocation (CPI) to the registry to mark the energy as claimed (mark_erc_claimed), together with validate_erc_for_trading, transfer_erc, and revoke_erc.
- DAO voting system: create_proposal → cast_vote (weighted by generation) → execute_proposal, restricted to modifying only the defined parameters of the ZoneConfig, without touching the PoA authority (the details of weighting and quorum are in @sec:consortium-network).
- Aggregator allow-list system: admit_aggregator and revoke_aggregator (authority only), where each entry is a dedicated PDA account that performs the admission of an off-chain validator node one at a time.

The program's state accounts are PDA accounts whose addresses are deterministically derived from specific seeds, as summarized in @tbl:governance-accounts.

#figure(
  caption: [State accounts (PDA) of the governance program: seeds and stored data. The GovernanceConfig account is a singleton with a fixed size of 405 bytes to support upgrades, while the remaining accounts are created one entry per entity (per-cert / per-node / per-zone / per-proposal).],
  text(size: 8pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal")
    #table(
      columns: (auto, auto, 1fr),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, left + horizon, left + horizon),
      table.header([Account (PDA)], [Seed], [Stored data]),
      [`GovernanceConfig`], [`[poa_config]`], [singleton: authority, pending_authority, ERC policy, maintenance flag, min_quorum_votes, and counters],
      [`ErcCertificate`], [`[erc_certificate,` `cert_id]`], [REC: owner, energy (kWh), status, expiry date],
      [`AggregatorEntry`], [`[aggregator,` `pubkey]`], [admitted off-chain validator node (allow-list)],
      [`ZoneConfig`], [`[zone_config,` `zone_id]`], [per-zone parameters: wheeling charge, incentive, loss factor],
      [`Proposal`], [`[proposal,` `zone, id]`], [DAO proposal: target parameter, votes for/against, status, expiry time],
      [`VoteRecord`], [`[vote,` `proposal, voter]`], [one vote per (proposal, voter) pair],
    )
  ],
) <tbl:governance-accounts>

The point that makes governance truly a control plane is the way other programs consume its state. The trading program reads the GovernanceConfig account on every order-creation instruction, then calls is_operational() to block operation when the system is in maintenance mode, along with checking the validity of the ERC before accepting a sell order; while the oracle program checks the AggregatorEntry account to allow only admitted nodes (or the designated chain bridge) to submit readings via submit_meter_reading. Both cases are read-only state accesses that deserialize the account themselves and check the owner and the PDA address without invoking a CPI, which avoids the cost of a CPI and reduces policy enforcement (gating) to merely checking the accounts submitted within that transaction. In this sense the AggregatorEntry account is the on-chain record of the admission of an off-chain validator node, enforced for real at the point where the oracle admits a reading into the system.

This structure reflects two separate PoA layers: the operational layer that determines who is authorized to run a validator on the permissioned network, and the application layer where GovernanceConfig.authority controls the program-administration rights, with the DAO being power-bounded to adjusting only zone parameters and unable to seize the authority's power or modify the validator allow-list. Furthermore, the GovernanceConfig account is fixed at a constant size of 405 bytes with reserved space (`_reserved`) for upgrades, so that new fields can be added without migrating existing accounts — a design discipline that is necessary when other programs each rely on this account's layout to deserialize it themselves.

The lifecycle of the ERC certificate is designed around the anti-double-claim property. Before issuing a certificate, the issue_erc instruction computes the unclaimed energy as $"unclaimed" = "total_generation" - "claimed_erc_generation" - "settled_net_generation"$ in a saturating manner, then enforces that the requested issuance amount must not exceed this value ($"energy_amount" <= "unclaimed"$); otherwise it is rejected. It also checks the policy from GovernanceConfig via can_issue_erc() (the system must be operational and have the ERC check enabled, and the amount must be within the range of min_energy to max_erc). When the conditions are met, the program invokes a CPI to the registry to increment the claimed-energy counter (mark_erc_claimed), so that the same unit of energy cannot be certified twice. A newly issued certificate has the status Valid but sets validated_for_trading to false until it passes the validate_erc_for_trading instruction (it must be operational, in the Valid status, and not yet expired), which is a mandatory condition before a certificate can back a trade order. The revoke_erc and transfer_erc instructions control revocation (preventing double revocation) and transfer of rights (allowed only when certificate transfer is enabled or it is a transfer from the issuer itself), with every handler updating the aggregate counters in GovernanceConfig (the number of certificates issued/validated/revoked and the cumulative energy certified).

The DAO proposal lifecycle has several layers of guards beyond the generation-weighted vote (described in @sec:consortium-network). The create_proposal instruction rejects a non-positive voting period and enforces that the proposer be the owner of the referenced meter, by reading the MeterAccount account zero-copy then checking that meter.owner matches the proposer. The cast_vote instruction is accepted only when the proposal is in the Active status and the time has not yet passed expires_at, otherwise it is rejected with ProposalExpired, and the voter must likewise be the owner of a meter. Double-voting is prevented with a VoteRecord PDA account per (proposal, voter) pair, where the second creation of the account fails because the account already exists. The execute_proposal instruction enforces that the time has passed expires_at first, then tallies the result automatically: if the total votes are below quorum (min_quorum_votes) the proposal is rejected, while if quorum is reached and the votes in favor exceed those against the proposal passes (a tie counts as rejected); and when it passes it may adjust only four ZoneConfig parameters, namely the incentive multiplier, wheeling charge, loss factor (which must be positive), and maintenance mode, reaffirming the DAO's bounded authority.

The maintenance mechanism exhibits the property of a system-wide kill switch through a single-point account write. When the authority calls set_maintenance_mode(true), a single boolean value on the singleton GovernanceConfig account is flipped, causing every order-creation instruction in the trading program in every zone to be rejected immediately with MaintenanceMode, without redeploying the trading program. The read on the trading side skips the first 8-byte discriminator of the account then decodes Borsh directly according to the struct layout, so the gate is tolerant to changes in the governance account's discriminator as long as the field order does not change, consistent with the fixed account size and reserved space mentioned above.

=== Registry: Validator Registration and Bond <sec:registry-program>
The registry program is the central registry of users, meters, and validators. The register_user and register_meter instructions create UserAccount and MeterAccount accounts zero-copy, bound to the owner via a PDA. Beyond its registry role, this program also holds the validators' security bond: register_validator requires staking a minimum of 10,000 GRX (MIN_VALIDATOR_STAKE) before being granted validator status, while stake_grx transfers GRX into the central treasury with a 24-hour withdrawal cooldown. When a validator misbehaves, the slash_validator instruction, signed by the PoA authority, slashes the bond proportionally to the severity, namely $"slash" = floor("bond" times "slash_bps" slash 10000)$, paying compensation to the injured party not exceeding the proven loss ($"compensation" = min("slash", "proven_loss")$), with the remainder going to the slash fund to remove the incentive for accusations made in hope of reward. A full slash changes the status to Slashed (permanent, re-registration prohibited), while a partial slash that drops below the minimum changes it to Suspended (recoverable by topping up the bond). This stake-and-slash mechanism is an economic incentive that complements the PoA admission control. In addition, the initial grant of 10 GRX to new users is separated out of register_user into a distinct claim_airdrop instruction (which invokes a CPI to energy-token to mint, signed by the registry's PDA) so that registration does not fail the whole transaction if the mint has a problem.

=== Oracle: Parallel Reading Ingest and Market Clearing <sec:oracle-program>
The oracle program ingests meter readings on-chain via submit_meter_reading, designed to write to a per-meter MeterState account (seed `[meter, meter_id]`) while the central OracleData account is read-only. Readings from different meters therefore have non-overlapping write sets and can be processed in parallel under the Sealevel model. However, the code states the real-world constraint that parallelism occurs only when the signers paying the fee (the fee payers) differ; if multiple readings use the same gateway signer, those entries are still processed sequentially because the payer account is write-locked. Before accepting a reading, the program checks for anomalies by checking the energy-value range (min/max) and the production-to-consumption ratio, computed as integers to avoid floating-point numbers ($"produced" times 100 <= "max_ratio" times "consumed"$). The right to submit readings is limited to the designated chain bridge, or to nodes in the governance allow-list, via the AggregatorEntry account check in authorize_node_caller (see @sec:governance-control-plane). Market clearing is done via trigger_market_clearing, which enforces that the epoch window boundary align to 900 seconds (`epoch_timestamp % 900 == 0`) and records last_cleared_epoch to prevent re-clearing or going back in time.

=== Energy Token: Idempotent Minting and REC Governance <sec:energy-token-program>
The energy-token program manages the minting of energy tokens under the governance of the REC certifying committee. All three minting paths (mint_to_wallet, mint_generation, mint_tokens_direct) require the signer to be in the set of REC certifiers (up to 5) once certifiers have been set (`rec_validators_count > 0`), making it a co-signature of the renewable-energy certifying authority before minting tokens. The mint_generation instruction, which creates tokens from actual generation, guarantees idempotency per time window using a GenerationMintRecord account per (meter_id, window_start_ms) pair, created with init_if_needed and enforced to align the window boundary to 900,000 milliseconds, setting the minted flag to true only after a successful mint. A repeated call at the same window therefore returns a no-op, and if the mint fails the flag remains false so it can be retried. The mint_tokens_direct instruction is the CPI target that the registry invokes to grant the initial tokens, while burn_tokens burns tokens through the SPL Token-2022 instruction. The TokenInfo account, which stores the certifier set and counters, is zero-copy so that the high-frequency path can read it without a write lock.

=== Treasury: Settlement Recording and THBC Peg <sec:treasury-program>
The treasury program is the CPI endpoint for recording settlements from the trading program and is the financial core of the system. Batch settlement recording (record_settlement_batch) writes a SettlementRecord account per (zone_id, batch_id) pair that stores the merkle root (merkle_root, 32 bytes), the total value, and the value-added tax (vat_amount, vat_rate_bps) as a commitment for retrospective auditing, where the merkle root binds the set of transactions in the batch on-chain while the leaves of the tree are stored off-chain. This base instruction reconciles the central total (total_settled_thbc) directly. To support a large number of concurrent settlements without the treasury account becoming a bottleneck, there is a parallel instruction (record_settlement_batch_sharded) that records the SettlementRecord as before but adds the amount to a per-shard accumulator account instead of the central total, partitioned into 16 shards (`settle_shard_for(key) = key[0] % 16`), then reconciled into the center afterward with aggregate_settlement_shards. On the THBC stablecoin peg, the swap_grx_for_thbc instruction enforces that the new supply must not exceed the attested reserve (`new_supply <= attested_reserve`) and that the attestation has not yet expired (`now - attestation_ts <= attestation_ttl`), while redeem_thbc_for_grx limits redemption so that it does not exceed the collateral in the vault (`grx_out <= swap_vault.amount`). In addition, staking GRX to earn rewards uses a MasterChef-style accumulator (acc_reward_per_share scaled by $10^12$) that increases according to the rewards added ($"delta" = "amount" times "ACC" slash "total_staked"$), and when a slash occurs the bond is redistributed to the remaining stakers through an increase of the same accumulator.

=== Parallelism via Sealevel and Sharding <sec:sealevel-sharding>
A design pattern that recurs across several programs is the use of a per-entity PDA account, so that unrelated transactions have non-overlapping write sets and can be processed in parallel under Solana's Sealevel model. Examples include the per-meter MeterState account in the oracle program, the per-order Order and order nullifier accounts in the trading program, and the per-user escrow account. For aggregate counters that would become a bottleneck if written to a single account (such as the cumulative user count, or the cumulative settled total), the system uses sharding into 16 shards deterministically derived from the first byte of the key (`key.to_bytes()[0] % 16`), both in the registry program (users and meters) and the treasury (settled amounts), and then reconciles into the central counter afterward with administrator-level instructions (aggregate_shards, aggregate_settlement_shards, and aggregate_readings) that prevent double-counting with a bitmask. As a result, central accounts such as GovernanceConfig, OracleData, and Market are designed to be readable in a stale manner on high-frequency paths, accepting that the aggregate value lags slightly in exchange for parallelizable throughput. This design is consistent with the slot-time target near 400 milliseconds referenced in @sec:consortium-network. The actual on-chain transaction throughput is measured on a single validator and reported in @sec:onchain-throughput, while the figures on a multi-node permissioned network that include the consensus cost remain future work (see @sec:settlement-cost).

== Data Model and Trust Boundary
The core data of a trade order consists of order_id, user_id (the prosumer or consumer role), meter_id, side (offer or bid), energy_amount (quantity_kwh), price_per_kwh, status, expires_at, epoch_id, and zone_id, where the energy_amount must not exceed the available_surplus_kwh that the Aggregator Bridge certifies for the seller in the same time period — a condition checked in the off-chain layer. Replay prevention uses an on-chain nullifier account (order nullifier) rather than storing a nonce in the order itself. The settlement record consists of trade_id, the buy_order_id/sell_order_id pair, the cleared energy_amount, price, fee_amount/net_amount, wheeling_charge, loss_factor, erc_certificate_id, blockchain_tx, and the settlement timestamps (created_at/confirmed_at). The escrow state is stored separately as its own PDA account (an SPL token account under the seed `escrow`), not within the settlement record.

The auditability that enables the blockchain to serve as an audit layer comes from the event log emitted by the programs at every important step of the trading cycle, namely order creation (SellOrderCreated, BuyOrderCreated), matching and settlement via the OrderMatched event that records the order pair, the buyer and seller, the quantity, price, total value, and fee, emitted from both settle_offchain_match and batch_settle_offchain_match, order cancellation (OrderCancelled), bond deposit (EscrowDeposited), and market clearing (AuctionCleared). Batch settlement recording in the treasury layer emits the SettlementBatchRecorded event that binds the batch's merkle root on-chain. These events are append-only records not modified retrospectively, which external auditors use to assemble an auditable transaction history without having to trust the off-chain layer directly, consistent with the settlement and audit layer role described in @sec:settlement-model.

The boundaries of responsibility are defined clearly as follows: the Backend and the Aggregator Bridge are the ones that assess the generation and consumption data, the grid-stability conditions, Islanding safety, network constraints, and the condition that the kWh quantity does not exceed the certified value (available_surplus); then the order pairs that pass the conditions are sent to the on-chain settlement stage. The Anchor program checks only account ownership, the signer, the Ed25519 signatures of both buyer and seller on the order payload, timestamp validity (expires_at), replay prevention via the order nullifier account, the slippage/zone-capacity conditions, the escrow state, and the order/trade state not yet reused. That is, the conditions on energy quantity and oracle attestation are enforced in the off-chain layer before submission and are not re-checked on-chain. Therefore, in this prototype the blockchain serves as a settlement and audit layer, not as a full power-flow or grid-stability engine.

== Trade Lifecycle Sequence
The trading sequence is clearly scoped between off-chain and on-chain, as in @fig:trade-lifecycle. The off-chain side is responsible for collecting Smart Meter data, authentication, verifying the reference time, assessing the grid-stability conditions, and computing the order pairs proposed for clearing. The on-chain side is responsible only for confirming the account state, the Ed25519 signatures of the buyer and seller on the signed order payload, the bounded matched pair, the escrow, and recording the settlement event.

This process makes energy transactions transparent and auditable while reducing the risk of bringing unverified Smart Meter data directly onto the blockchain. The separation of the boundary between off-chain verification and on-chain settlement is therefore a key principle in preserving both system performance and the safety of the microgrid. The limitation of this approach is that users must trust the Aggregator Bridge and the governance of the oracle_authority; to further reduce trust, one should add multi-oracle attestation or cryptographic proofs in the future.

#figure(
  placement: top,
  scope: "parent",
  text(size: 7pt)[
    // Keep inline math/code at diagram text size (template oversizes math to 10pt).
    #show math.equation: set text(size: 7pt)
    #show raw: set text(size: 6.5pt)
    // Auto-scale the sequence diagram down to the available (parent) width so it
    // never overflows the page, regardless of participant/note widths.
    #layout(size => {
    let __d = chronos.diagram({
      import chronos: *
      _par("Meter", display-name: "Smart Meter")
      _par("Agg", display-name: "Aggregator Bridge")
      _par("Trade", display-name: "Trading Service")
      _par("Anchor", display-name: "Anchor Programs")

      _grp("off-chain: verification · matching", {
        _seq("Meter", "Agg", comment: "signed reading Ed25519 / DLMS (15 min)")
        _seq("Agg", "Agg", comment: [verify sig · surplus · grid stability \[I3\]])
        _seq("Agg", "Trade", comment: "validated reading")
        _seq("Trade", "Trade", comment: [CDA price-time · landed cost $p^*$])
      })

      _seq("Trade", "Anchor", comment: [submit `settle_offchain_match`], color: rgb("#c77d3c"))

      _grp("on-chain: atomic DvP settlement", {
        _note("over", [verify sig · price-cross], pos: "Anchor")
        _note("over", [nullifier · zone-cap], pos: "Anchor")
        _note("over", [atomic DvP transfer], pos: "Anchor")
        _note("over", [fail → revert all], pos: "Anchor", color: rgb("#fbeeee"))
      })

      _seq("Anchor", "Trade", comment: [emit `OrderMatched` · `record_settlement`], dashed: true)
    })
    let __f = calc.min(1.0, size.width / measure(__d).width)
    scale(x: __f * 100%, y: __f * 100%, reflow: true, __d)
    })
  ],
  caption: [Trade lifecycle as a sequence diagram: off-chain participants (Smart Meter → Aggregator Bridge → Trading Service) verify and match, then submit to the on-chain Anchor Programs (via the Chain Bridge) which settle and audit. Notes tag the on-chain checks enforced during settlement (described in @sec:settlement-model); any failed CPI reverts the whole atomic DvP settlement.],
) <fig:trade-lifecycle>
