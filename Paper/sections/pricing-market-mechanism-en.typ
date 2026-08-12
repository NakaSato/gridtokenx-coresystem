= PRICING AND MARKET MECHANISM <sec:pricing-market-mechanism>

_A Continuous Double Auction clears trades transparently, with fee, seller-net, and treasury token-pricing computed at settlement._

== Pricing and Settlement Model <sec:pricing-model>
The pricing model of this system is divided into three parts: clearing-price determination in the CDA mechanism, fee and seller-net computation at settlement, and the token pricing mechanism at the treasury layer. The symbols used in the equations are summarized in @tbl:nomenclature.

#figure(
  text(size: 8pt)[
    // Override the template's global `show math.equation: set text(size: 10pt)`
    // so symbols match the (smaller) table text instead of staying at 10pt.
    #show math.equation: set text(size: 8pt)
    #table(
    columns: (auto, 1fr),
    inset: (x: 4pt, y: 3pt),
    align: (center + horizon, left + horizon),
    table.header([Symbol], [Meaning]),
    [$p_s$], [unit sell ask price],
    [$p_b$], [unit buy bid price],
    [$p^*$], [clearing price / landed cost],
    [$lambda$], [loss factor ($lambda >= 1$)],
    [$c_("loss")$], [unit loss cost],
    [$w$], [wheeling charge per unit],
    [$m$], [incentive multiplier],
    [$q$], [matched energy quantity (kWh)],
    [$V$], [total transaction value],
    [$f$], [market fee],
    [$phi$], [market fee rate (bps)],
    [$W$], [total wheeling charge ($q dot w$)],
    [$L$], [total loss cost ($q dot c_("loss")$)],
    [$r$], [exchange rate, GRX atoms per THBC],
    [$psi$], [swap fee (bps)],
    [$A$], [reward accumulator per unit stake],
    [$s$, $s_("total")$], [staked amount and total staked amount],
    [$R$], [reward funded into the system],
    )
  ],
  caption: [Nomenclature for the pricing and settlement equations.],
) <tbl:nomenclature>

Clearing-price determination (CDA clearing) uses the seller-side price (maker price) adjusted by network costs. The per-unit loss cost is defined from the loss factor $lambda >= 1$ as in the equation
$ c_("loss") = p_s (lambda - 1) $ <eq:loss-cost>
The clearing price, or landed cost, is computed from the sell ask price $p_s$ plus the wheeling charge $w$ and the loss cost, then adjusted by the incentive multiplier $m$
$ p^* = (p_s + w + c_("loss")) dot m $ <eq:clearing>
An order can be matched when $p^* <= p_b$ (where $p_b$ is the buy bid price), and the system orders sellers with the lowest landed cost to be matched first under price-time priority. The matched quantity equals the smaller of the two sides' remaining amounts, $q = min(q_b, q_s)$.

This price $p^*$ is what the trade actually *settles* at, not merely a matching filter: the buyer's escrow is debited $q dot p^*$, and the fee, wheeling charge and loss cost are then split out to their respective collector accounts, leaving the remainder for the seller. That property is what makes $w$ and $c_("loss")$ genuine pass-through costs borne by the buyer, with the seller retaining approximately $q dot p_s$.

There is no longer an intra-zone discount. A multiplier $delta = 0.95$ was formerly applied to same-zone pairs, but once $p^*$ became the settled price, any factor below one would put the settled price beneath the seller's ask — which the on-chain program rejects via `match_price >= seller.price_per_kwh` (`SlippageExceeded`). Reinstating such a discount therefore requires an explicit funding source, for example a rebate from the wheeling collector, rather than a bare multiplier on the clearing price.

The fee and seller-net computation at settlement defines the total value, the market fee, and the seller's net amount as follows
$ V &= q dot p^* #<eq:value> \
  f &= (V dot phi) / 10000 #<eq:fee> \
  "net" &= V - f - W - L #<eq:net> $
where $phi$ is the market fee in basis points (the on-chain default is 25 bps, or 0.25%), $W = q dot w$ is the total wheeling charge, and $L = q dot c_("loss")$ is the total loss cost. The amounts $f$, $W$, $L$, and net are transferred separately to the fee-collector, wheeling, loss, and seller accounts respectively. The incentive multiplier is interpreted in bps, namely $m = m_("bps") slash 10000$. The wheeling charge $w$ is *not* a bps value but a flat per-kWh rate read from the on-chain `TariffConfig` account (the deployed value is 0.10 baht per kWh), and the loss factor derives from `TariffConfig.loss_bps` (deployed value 5 bps, i.e. $lambda = 1.0005$). Neither rate has a zone dimension: the on-chain program applies the same rates to every match, intra-zone or cross-zone alike.

To illustrate the use of the equations above, consider a single match with sell ask price $p_s = 4.00$ baht per kWh, quantity $q = 10$ kWh, and the deployed rates ($lambda = 1.0005$, $w = 0.10$, $m = 1$, $phi = 25$ bps). From @eq:loss-cost we obtain $c_("loss") = 4.00(1.0005 - 1) = 0.002$, and from @eq:clearing the clearing price $p^* = (4.00 + 0.10 + 0.002) dot 1 = 4.102$ baht per kWh, which can be matched when the buy bid price $p_b >= 4.102$. The total value is then $V = 10 dot 4.102 = 41.02$ baht, the fee $f = 41.02 dot 25 slash 10000 approx 0.103$ baht, the total wheeling charge $W = 10 dot 0.10 = 1.00$ baht, and the total loss cost $L = 10 dot 0.002 = 0.02$ baht, giving the seller a net amount of $"net" = 41.02 - 0.103 - 1.00 - 0.02 approx 39.90$ baht, or 3.99 baht per kWh. Note that this equals the seller's ask revenue ($10 dot 4.00 = 40.00$ baht) less only the market fee: the 1.00 baht wheeling charge is borne entirely by the buyer. The actual computation in the code uses floor-rounded fixed-point integers, so the resulting values may differ from this example at the rounding-fraction level.

The token pricing mechanism at the treasury layer covers the exchange between GRX and the THBC stablecoin pegged to the baht, using the rate $r$ (number of GRX atoms per THBC) and the swap fee $psi$ (bps)
$ "thbc" &= (g dot r) / 10^9 dot (1 - psi slash 10000) #<eq:swap> \
  g &= ("thbc" dot 10^9) / r #<eq:redeem> $
where redemption per @eq:redeem incurs no fee, and the peg is maintained using a 1:1 supply-to-reserve condition, namely $"supply"_("thbc") <= "reserve"_("attested")$. Staking rewards use a MasterChef-style accumulator, where a staker's accrued reward is computed from the staked amount $s$
$ "reward" = s dot A slash 10^12 - "debt" $ <eq:reward>
When a reward $R$ is funded, the accumulator $A$ is updated to $A <- A + (R dot 10^12) slash s_("total")$ pro-rata by stake share, and a slash deducts the requested amount but not more than the staked principal (capped at principal), then redistributes it back to the remaining stakers through the same accumulator.

On the production CDA path, the incentive multiplier is set to $m = 1$; that is, the incentive multiplier takes effect only on the feed-in or grid-export settlement path, not on CDA matching. In addition, the on-chain default of the market fee (25 bps) differs from the default in the off-chain configuration file (50 bps), and the zone parameters in the governance program are stored at ×1000 scale, while the consumer of the actual values in the trading layer interprets them in bps ($slash 10000$), which is the value the system actually uses. The computation in the code uses floor-division fixed-point integers, and the seller net uses checked arithmetic that rejects a transaction when the total fees exceed the matched value (with a network fee ceiling of 20%) instead of clamping the amount down to zero. Therefore the equations above constitute a real-value model that may differ from the actual computed result at the rounding-fraction level.

One point about the wheeling charge $w$ deserves emphasis, namely where the value comes from. The off-chain matcher formerly used zone-split constants hard-coded in the service (zero intra-zone and 0.02 cross-zone) while the on-chain program deducted the flat per-unit rate held in `TariffConfig`. The two layers therefore charged different rates, and the difference fell silently on the seller. The matcher now reads the same `TariffConfig` rates used at settlement, so landed-price formation and ledger accounting reference one set of numbers. That rate is set by the wheeling authority (the distribution utility).

The `wheeling_charge_bps` field on the `ZoneConfig` account remains declared on-chain with no code path reading it, so governance of the *per-zone* wheeling rate remains an open design gap — as does the incentive multiplier $m$, which `ZoneConfig` supports but which the current deployment never creates, leaving the matcher to use $m = 1$ throughout.

== Sensitivity of Seller Net and P2P Trading Uplift <sec:revenue-sensitivity>
To show the economic implications of the pricing model above, this section analyzes the sensitivity of the seller's net amount to the zone parameters and the fee. This is a purely model-derived computation from the settlement equations in @eq:clearing and @eq:net, not a measurement of revenue from running the real system. We fix the base sell ask price $p_s = 4.00$ baht per kWh, the matched quantity $q = 10$ kWh, and the incentive multiplier $m = 1$ (per the real CDA path), then vary the intra-zone/cross-zone state, the fee rate $phi$, and the loss factor $lambda$ as in @tbl:revenue-sensitivity.

#figure(
  caption: [Model-derived seller-net sensitivity computed from @eq:clearing and @eq:net at $p_s = 4.00$ ฿/kWh, $q = 10$ kWh, $m = 1$. "net" is the seller's settled amount. Because the trade settles at the landed price $p^*$, wheeling ($w$) and loss ($lambda$) are genuine pass-throughs: raising $w$ fivefold (S3) or $lambda$ tenfold (S4) leaves the seller's net essentially unchanged, while the market fee $phi$ (S2) is what actually moves it.],
  text(size: 8pt)[
    #show math.equation: set text(size: 8pt)
    // Each scenario is computed from the settlement equations — never hand-typed —
    // so the table cannot drift from the model. m = 1 on the CDA path.
    #import "../metrics.typ": pricing
    #let scen(name, lambda, w, phi) = {
      let ps = pricing.ps
      let q = pricing.q
      let closs = ps * (lambda - 1)            // eq:loss-cost
      let pstar = (ps + w + closs)             // eq:clearing (m = 1)
      let value = q * pstar                    // eq:value
      let fee = value * phi / 10000            // eq:fee
      let wheel = q * w
      let loss = q * closs
      let net = value - fee - wheel - loss     // eq:net
      (name, w, lambda, phi, pstar, net, net / q)
    }
    #let rows = (
      scen([S1 deployed rates], 1.0005, 0.10, 25),
      scen([S2 high fee], 1.0005, 0.10, 100),
      scen([S3 wheeling x5], 1.0005, 0.50, 25),
      scen([S4 loss x10], 1.005, 0.10, 25),
    )
    // Guard: S1 must reproduce the worked example in @sec:pricing-model (39.90 ฿).
    #assert(
      calc.round(rows.at(0).at(5), digits: 2) == 39.9,
      message: "revenue table S1 drifted from the worked example (39.90 ฿)",
    )
    #table(
      columns: 7,
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon,) + (center + horizon,) * 6,
      table.header(
        [Scenario], [$w$ (฿/kWh)], [$lambda$], [$phi$ (bps)],
        [$p^*$], [net (฿)], [net/kWh],
      ),
      ..rows.map(r => (
        r.at(0),
        [#calc.round(r.at(1), digits: 2)],
        [#calc.round(r.at(2), digits: 4)],
        [#calc.round(r.at(3))],
        [#calc.round(r.at(4), digits: 3)],
        [#calc.round(r.at(5), digits: 2)],
        [#calc.round(r.at(6), digits: 2)],
      )).flatten(),
    )
  ],
) <tbl:revenue-sensitivity>

From @tbl:revenue-sensitivity, two important patterns are visible. First, the seller's net amount barely changes even under large increases in the wheeling charge $w$ or the loss factor $lambda$: S3 raises wheeling fivefold and S4 raises loss tenfold, yet the net stays at roughly 39.89 baht, the same as the base case. Both costs are added into the landed price $p^*$ the buyer actually pays and then split off to the wheeling-collector and loss accounts, so they are pass-through costs that do not reduce the seller's amount; the seller consistently receives close to $q dot p_s$. Second, the only variable that materially affects the seller is the market fee rate $phi$, which is deducted directly from the total value: raising it from 25 to 100 bps (S1 → S2) reduces the net amount by about 0.31 baht.

Compared with a flat feed-in tariff for surplus power under a hypothetical citizen-solar program assumed at around 2.20 baht per kWh, the seller's per-unit net amount in the P2P market (approximately 3.96–3.99 baht per kWh) represents an uplift of about 80–81%. At the same time, the buyer pays a landed price $p^*$ (approximately 4.10–4.50 baht per kWh) that remains lower than the usual retail electricity price, so gains from trade arise on both sides. Here the 2.20-baht purchase rate is merely a hypothetical reference value for comparison, not a value measured from a real market.

A limitation of this analysis is that the numbers in @tbl:revenue-sensitivity are model-derived results under fixed parameters and a single matched quantity (10 kWh). Moreover, the actual computation in the code uses floor-rounded fixed-point integers, so the resulting values may differ at the rounding-fraction level, and this is not itself a measurement of revenue distribution under a full-scale simulated workload. That measurement is carried out in @sec:price-mechanism-revenue, which compares seller-side net revenue under three price mechanisms across five fleet sizes; full welfare measurement remains future work (see @sec:discussion_limitations).

== Continuous Double Auction Matching <sec:cda-matching>
The market mechanism uses Continuous Double Auction (CDA) matching that orders by price-time priority and accounts for the topological constraints of the power network. Sell orders are partitioned into a zone-segmented order book, where each zone stores sell orders in an ordered structure (BTreeMap) keyed by `(price, created_at, id)`, so that the key ordering prioritizes the lowest price first, then the earlier order-creation time, and uses the order id as the final tie-breaker, thereby yielding price-time priority implicitly without re-sorting. Orders whose remaining quantity falls below the minimum threshold (MIN_TRADE_AMOUNT) or that have expired are not inserted into the book.

For each buy order, the matching engine gathers candidate sellers only from zones from which the network can deliver energy to the buyer's zone, via two-stage topology pre-filtering: the first stage checks at the minimum quantity to immediately exclude zones that cannot reach each other, and the second stage re-checks at the actual matched quantity (`can_accommodate_flow(sell_zone, buy_zone, amount)`) to enforce the transmission-line capacity ceiling. Within each reachable zone, a range query is used to retrieve only sell orders whose ask price does not exceed the bid price, then the landed cost is computed per @eq:clearing (including wheeling, loss cost, and the multiplier). Only sell orders whose landed cost does not exceed the bid price ($p^* <= p_b$) pass through as candidates. The system prevents self-trade by skipping pairs where the buyer and seller are the same user.

Once candidates from all reachable zones are obtained, the system consolidates the list and sorts by landed cost from low to high, so the buyer gets the cheapest landed total price first, regardless of which zone that sell order is in. It then matches progressively, with the per-pair quantity equal to the smaller remaining amount of the two sides ($q = min(q_b, q_s)$) as a partial-fill, and immediately removes sell orders whose remaining quantity falls below the threshold from the book. For Fill-or-Kill (FOK) buy orders, the system first checks whether the total candidate quantity is sufficient for the entire order; if not, it does not match at all. In addition, there is match consolidation when the same buyer-seller pair and the same price occur consecutively, to reduce the number of settlement records that must be sent on-chain. Each match result records the match price (landed cost), wheeling charge, loss cost, and source/destination zones, before sending the matched pairs to atomic settlement per @sec:settlement-model. The on-chain processing cost of the settlement path fed by the matching engine is reported in @sec:settlement-cost, while the matching throughput of the matching engine in the in-memory layer is reported in @sec:matching-throughput.
