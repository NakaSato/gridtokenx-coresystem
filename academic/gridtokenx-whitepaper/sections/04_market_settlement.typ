= Market Mechanics and Settlement

The GridTokenX energy market is designed to achieve efficient price discovery and real-time settlement while maintaining the physical constraints of the underlying power grid. The market architecture draws from established financial market microstructure theory @friedman1993 and adapts it to the unique requirements of energy trading.

== Market Design Principles

The platform's market design is guided by four core principles:

*Price Discovery*: Market prices should reflect the true marginal cost of energy production and delivery, incorporating generation costs, transmission losses, and grid congestion.

*Fairness*: All participants should have equal access to market information and equal treatment under the matching rules. No participant should be able to gain an unfair advantage through information asymmetry or preferential treatment.

*Physical Feasibility*: Every settled trade must be physically deliverable. The market must enforce grid capacity constraints to prevent trades that would cause network congestion or voltage violations.

*Settlement Finality*: Once a trade is matched and settled on-chain, it is irrevocable. Participants can rely on atomic settlement without counterparty risk.

== The Continuous Double Auction (CDA) Matching Engine

=== Why CDA over AMM

Automated Market Makers (AMMs), popularized by DeFi protocols like Uniswap, use algorithmic pricing curves (e.g., $x \cdot y = k$) to provide liquidity. While AMMs are well-suited for fungible token trading with continuous liquidity, they are poorly suited for energy markets for several reasons:

- Energy supply and demand are highly time-dependent and location-specific. A prosumer in Bangkok cannot deliver energy to a buyer in Chiang Mai without incurring transmission costs.
- AMMs cannot express limit orders, preventing prosumers from setting minimum acceptable prices for their energy.
- AMM pricing is reactive rather than predictive, leading to significant slippage during demand spikes.

The Continuous Double Auction (CDA) @friedman1993 is the standard mechanism for organized financial exchanges (NYSE, NASDAQ, CME) and has been extensively studied in the context of energy markets @kok2016. In a CDA:
- Sellers submit *ask orders* specifying the minimum price they will accept per kWh.
- Buyers submit *bid orders* specifying the maximum price they will pay per kWh.
- The matching engine continuously matches compatible bid-ask pairs based on price-time priority.

=== Order Types

GridTokenX supports the following order types:

*Limit Order*: The standard order type. Specifies exact price and quantity. Executed only at the specified price or better.

*Market Order*: Executed immediately at the best available price. Used by buyers who prioritize speed over price certainty.

*Time-in-Force Options*:
- `GTC` (Good Till Cancelled): Order remains active until filled or explicitly cancelled.
- `GTD` (Good Till Date): Order expires at a specified timestamp, useful for prosumers who want to sell energy only during peak hours.
- `IOC` (Immediate or Cancel): Fill as much as possible immediately, cancel the remainder.

=== Matching Algorithm

The matching engine maintains two sorted data structures:
- *Ask Queue*: Sorted ascending by price, then by submission timestamp (price-time priority).
- *Bid Queue*: Sorted descending by price, then by submission timestamp.

On each new order submission, the engine checks for crossing orders:

```
function match(new_order):
  if new_order.side == BID:
    while ask_queue.top().price <= new_order.price and new_order.qty > 0:
      ask = ask_queue.pop()
      fill_qty = min(ask.qty, new_order.qty)
      execute_trade(ask, new_order, ask.price, fill_qty)
      new_order.qty -= fill_qty
    if new_order.qty > 0:
      bid_queue.insert(new_order)
  else: // ASK
    while bid_queue.top().price >= new_order.price and new_order.qty > 0:
      bid = bid_queue.pop()
      fill_qty = min(bid.qty, new_order.qty)
      execute_trade(new_order, bid, new_order.price, fill_qty)
      new_order.qty -= fill_qty
    if new_order.qty > 0:
      ask_queue.insert(new_order)
```

The matching engine runs in the Trading Service (off-chain) for low-latency order processing. Matched pairs are batched and submitted to the on-chain Trading Program for atomic settlement.

=== Grid-Aware Order Filtering

Before an order is accepted into the order book, the Trading Service performs a grid feasibility check:
1. Retrieves the buyer's and seller's zone assignments from the Registry Program.
2. Queries the VPP Cluster state for both zones to verify available capacity.
3. Calculates the applicable wheeling charge and Grid Loss Factor for the buyer-seller zone pair.
4. Adjusts the effective trade price to include wheeling charges and loss costs.
5. Rejects orders that would exceed zone capacity limits with a `CapacityExceeded` error.

== Settlement Architecture

#figure(
  image("../figures/settlement_flow.svg", width: 100%),
  caption: [End-to-end settlement flow from order placement to on-chain atomic finality.],
) <fig-settlement>

=== Off-Chain vs. On-Chain Responsibilities

GridTokenX uses a hybrid settlement model that separates latency-sensitive matching from trust-critical settlement:

#table(
  columns: (1fr, 1fr),
  inset: 8pt,
  align: (left, left),
  [*Off-Chain (Trading Service)*], [*On-Chain (Trading Program)*],
  [Order book management], [Atomic token transfers],
  [Price-time priority matching], [Ed25519 signature verification],
  [Grid feasibility checks], [Nullifier replay protection],
  [Wheeling charge calculation], [Escrow release],
  [Batch assembly], [Fee distribution],
)

=== Escrow Mechanism

When a buyer places a bid order, the corresponding gTHB amount (price × quantity + maximum wheeling charge buffer) is locked in a program-owned escrow account. This ensures:
- The buyer cannot spend the escrowed funds while the order is active.
- Settlement is guaranteed once a match is found — there is no counterparty risk.
- If the order is cancelled or expires, the full escrowed amount is returned to the buyer.

=== Atomic Settlement Flow

For each matched pair, the on-chain `match_orders` instruction executes the following atomically:

1. *Signature Verification*: Verifies Ed25519 signatures for both buyer and seller order payloads via the `instructions` sysvar.
2. *Nullifier Check*: Verifies that neither order UUID has been previously settled.
3. *Oracle Confirmation*: Verifies that the seller's `MeterState` PDA has sufficient verified generation balance to cover the trade quantity.
4. *GRID Transfer*: Transfers `fill_qty` GRID tokens from the seller's token account to the buyer's token account.
5. *gTHB Transfer*: Transfers `fill_qty × trade_price` gTHB from the buyer's escrow to the seller's token account.
6. *Fee Deduction*: Transfers wheeling charges to the grid operator account and market fees to the protocol treasury.
7. *Nullifier Creation*: Creates `Nullifier` PDAs for both order UUIDs.
8. *Event Emission*: Emits a `TradeSettled` event with full trade details for off-chain indexing.

=== Batch Settlement

To maximize throughput and minimize transaction overhead, the Trading Program supports settling up to 4 order pairs per transaction. With Solana's 400ms block time and the ability to include multiple transactions per block, the platform can theoretically settle over 50,000 trades per hour — sufficient for a national-scale energy market.

== Fee Structure

=== Market Fees

A flat market fee of 0.1% of trade value is deducted from each settled trade and transferred to the protocol treasury. Treasury funds are governed by GRX token holders and used for protocol development, security audits, and ecosystem grants.

=== Wheeling Charges

Wheeling charges compensate grid operators for the use of transmission and distribution infrastructure. The charge structure is:

#table(
  columns: (auto, auto, 1fr),
  inset: 8pt,
  align: (left, center, left),
  [*Zone Relationship*], [*Base Rate (THB/kWh)*], [*Description*],
  [Intra-zone], [0.50], [Buyer and seller in same low-voltage zone],
  [Adjacent zone], [1.00], [One zone boundary crossed],
  [Distant zone], [1.50 + 0.10×d], [Multiple zone boundaries; d = zone distance],
)

Where zone distance $d$ is the number of zone boundaries between buyer and seller, as defined in the platform's zone topology graph.

=== Grid Loss Factor (GLF)

The GLF accounts for resistive losses during energy transmission. It is calculated as:

$ "GLF" = 1 - e^{-alpha dot d} $

Where $alpha = 0.02$ is the loss coefficient per zone distance unit, calibrated against PEA transmission loss data. The loss cost is deducted from the seller's proceeds and transferred to the grid operator as compensation for physical energy losses.

== Order Book Transparency

The platform provides a public, real-time order book API that exposes:
- Current best bid and ask prices per zone pair.
- Market depth (aggregated volume at each price level).
- Recent trade history (last 1,000 trades per zone pair).
- 24-hour volume, high, low, and VWAP statistics.

This transparency enables prosumers to make informed trading decisions and supports price discovery across the network.
