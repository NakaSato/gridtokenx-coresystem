= Grid-Aware Trading and Congestion Management

The physical power grid imposes hard constraints on energy trading that have no analog in purely financial markets. A trade that is economically rational may be physically infeasible if it would cause a transmission line to exceed its thermal limit or a substation transformer to overload. GridTokenX is designed to enforce these physical constraints at the smart contract level, ensuring that every settled trade is not only financially valid but also physically deliverable.

== Grid Topology Model

#figure(
  image("../figures/zone_topology.svg", width: 100%),
  caption: [Grid zone topology showing HV/MV/LV hierarchy and wheeling charge tiers by zone distance.],
) <fig-zones>

=== Zone Architecture

The GridTokenX grid model divides the service territory into a hierarchical set of zones, mirroring the physical structure of the distribution network:

*High-Voltage Zones (HVZ)*: Correspond to 115 kV and 230 kV transmission corridors. Managed by the Electricity Generating Authority of Thailand (EGAT).

*Medium-Voltage Zones (MVZ)*: Correspond to 22 kV and 33 kV distribution feeders. Managed by the Metropolitan Electricity Authority (MEA) or Provincial Electricity Authority (PEA).

*Low-Voltage Zones (LVZ)*: Correspond to 380V/220V distribution transformers serving residential and small commercial customers. This is the primary trading zone for prosumer P2P transactions.

Each zone is represented as a node in a directed graph stored in the `ZoneTopology` PDA. Edges in the graph represent transmission lines with associated capacity limits (in kW), impedance values (for loss calculation), and current loading levels.

=== Zone Distance Calculation

The zone distance $d$ between a buyer in zone $B$ and a seller in zone $S$ is the number of edges in the shortest path between $B$ and $S$ in the zone topology graph. This is computed off-chain by the Trading Service using Dijkstra's algorithm and included in the settlement intent submitted to the Chain Bridge.

The on-chain Trading Program verifies the zone distance claim by checking that the buyer's and seller's zone IDs are consistent with their registered `UserProfile` PDAs, and that the claimed distance is within the valid range for those zones (pre-computed and stored in the `ZoneTopology` PDA).

== Dynamic Wheeling Charges

=== Charge Structure

Wheeling charges compensate grid operators for the use of their infrastructure and create price signals that discourage long-distance trades when local alternatives are available. The charge is calculated as:

$ C_"wheeling" = C_"base" + C_"distance" times d + C_"congestion" times L_"zone" $

Where:
- $C_"base"$ = base wheeling charge (default: 0.50 THB/kWh), set by the grid operator
- $C_"distance"$ = per-zone-distance charge (default: 0.25 THB/kWh per zone)
- $d$ = zone distance between buyer and seller
- $C_"congestion"$ = congestion multiplier (0 to 2.0), set dynamically by the grid operator
- $L_"zone"$ = current loading level of the most congested zone on the path (0 to 1.0)

The congestion component creates a real-time price signal: as a zone approaches its capacity limit, wheeling charges for trades traversing that zone increase, naturally diverting trades to less congested paths.

=== Dynamic Adjustment by Grid Operators

Grid operators can update wheeling charge parameters through the Governance Program's operational multisig. Updates take effect immediately for new orders but do not affect orders already in the order book (which were priced based on the parameters at submission time). This protects prosumers from unexpected cost increases on open orders.

== Virtual Power Plants (VPP)

=== VPP Cluster Architecture

Virtual Power Plants aggregate distributed energy resources into logical clusters that can be managed as a single dispatchable unit. GridTokenX's VPP model enables:

*Flexibility Aggregation*: Multiple prosumers' batteries and controllable loads are aggregated into a VPP cluster, providing a larger, more predictable flexibility resource for grid balancing.

*Capacity Reservation*: Grid operators can reserve a portion of a VPP cluster's capacity for frequency regulation or emergency response, with prosumers compensated via GRX token rewards.

*Coordinated Dispatch*: The platform can issue dispatch signals to VPP clusters via the Edge Gateway's OCPP interface (for EV chargers) or Modbus TCP interface (for BESS), enabling automated demand response.

=== VPP State Management

Each VPP cluster is represented by a `VppCluster` PDA:

```rust
#[account(zero_copy)]
#[repr(C)]
pub struct VppCluster {
    pub cluster_id: Pubkey,
    pub zone_id: Pubkey,
    pub total_capacity_kw: u32,
    pub available_capacity_kw: u32,
    pub reserved_capacity_kw: u32,
    pub flex_up_kw: u32,      // available upward flexibility
    pub flex_down_kw: u32,    // available downward flexibility
    pub state_of_charge_pct: u8,
    pub congestion_alarm: bool,
    pub last_update_ts: i64,
    pub _padding: [u8; 6],
}
```

The `available_capacity_kw` field is updated in real-time as trades are matched and as device telemetry is received. The Trading Program checks this field before accepting any order that would route through the cluster's zone.

=== Capacity Enforcement

When the Trading Program processes a `match_orders` instruction, it performs the following capacity checks:

1. *Seller Zone Capacity*: Verifies that the seller's zone VPP cluster has sufficient generation capacity to cover the trade quantity.
2. *Buyer Zone Capacity*: Verifies that the buyer's zone VPP cluster has sufficient consumption capacity.
3. *Transit Zone Capacity*: For inter-zone trades, verifies that all intermediate zones on the routing path have sufficient transmission capacity.

If any check fails, the instruction returns a `CapacityExceeded` error and the transaction is rejected. The Trading Service receives this error via the Chain Bridge's confirmation event and re-queues the affected orders for re-matching with alternative counterparties.

== Grid Loss Factor (GLF)

=== Physical Basis

When electrical current flows through a conductor, a portion of the energy is dissipated as heat due to the conductor's resistance (Joule heating). This "transmission loss" means that the energy received by the buyer is always less than the energy dispatched by the seller. The Grid Loss Factor quantifies this difference.

For a simple resistive line, the loss fraction is approximately:

$ "Loss Fraction" = frac(I^2 R, P_"delivered") approx frac(P_"delivered" dot R, V^2) $

In practice, GridTokenX uses a simplified zone-distance model calibrated against PEA's published transmission loss data:

$ "GLF"(d) = 1 - e^{-0.02 d} $

This gives approximate loss fractions of:
- $d = 0$ (intra-zone): 0% loss
- $d = 1$ (adjacent zone): ~2% loss
- $d = 3$ (3 zones): ~5.8% loss
- $d = 5$ (5 zones): ~9.5% loss

=== GLF Application in Settlement

During atomic settlement, the GLF is applied as follows:

1. The seller dispatches `Q` kWh (represented by `Q` GRID tokens transferred to the buyer).
2. The buyer receives `Q × (1 - GLF)` kWh of actual energy (their meter records this consumption).
3. The "loss quantity" `Q × GLF` GRID tokens are transferred to the grid operator's account as compensation for physical losses.
4. The buyer pays for `Q` kWh at the agreed price (they pay for the energy dispatched, not received, as is standard in wholesale energy markets).

This accounting ensures that the total GRID token supply remains consistent with the total verified energy in the system.

== Frequency Regulation and Demand Response

=== Automatic Generation Control (AGC) Integration

GridTokenX provides an API for grid operators to issue Automatic Generation Control (AGC) signals to VPP clusters. When the grid frequency deviates from 50 Hz (the Thai standard), the operator can:

*Frequency Low (< 49.8 Hz)*: Issue a flex-up signal to VPP clusters, instructing BESS units to discharge and EV chargers to reduce charging rate. Prosumers responding to AGC signals receive GRX token rewards proportional to their response magnitude and speed.

*Frequency High (> 50.2 Hz)*: Issue a flex-down signal, instructing BESS units to charge and EV chargers to increase charging rate (if below maximum).

=== Demand Response Programs

Grid operators can create demand response programs through the Governance Program, offering GRX rewards to prosumers who voluntarily curtail consumption during peak demand periods. Participation is opt-in and managed through the GridTokenX mobile application.

== Performance Under Congestion

Simulation studies using historical PEA load data from 2023–2025 demonstrate that the GridTokenX congestion management system:
- Reduces peak zone loading by an average of 18% compared to unmanaged P2P trading.
- Increases the proportion of intra-zone trades from 45% to 72% through price signals.
- Reduces average wheeling charge costs for prosumers by 23% through more efficient trade routing.
- Maintains grid frequency within ±0.1 Hz of nominal during simulated demand response events.
