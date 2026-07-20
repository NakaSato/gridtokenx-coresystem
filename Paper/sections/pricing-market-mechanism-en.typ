= PRICING AND MARKET MECHANISM <sec:pricing-market-mechanism>

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
    [$delta$], [intra-zone discount],
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
The clearing price, or landed cost, is computed from the sell ask price $p_s$ plus the wheeling charge $w$ and the loss cost, then adjusted by the incentive multiplier $m$ and the intra-zone discount $delta$
$ p^* = (p_s + w + c_("loss")) dot m dot delta $ <eq:clearing>
where $delta = 0.95$ when buyer and seller are in the same zone, and $delta = 1$ when crossing zones. An order can be matched when $p^* <= p_b$ (where $p_b$ is the buy bid price), and the system orders sellers with the lowest landed cost to be matched first under price-time priority. The matched quantity equals the smaller of the two sides' remaining amounts, $q = min(q_b, q_s)$.

The fee and seller-net computation at settlement defines the total value, the market fee, and the seller's net amount as follows
$ V &= q dot p^* #<eq:value> \
  f &= (V dot phi) / 10000 #<eq:fee> \
  "net" &= V - f - W - L #<eq:net> $
where $phi$ is the market fee in basis points (the on-chain default is 25 bps, or 0.25%), $W = q dot w$ is the total wheeling charge, and $L = q dot c_("loss")$ is the total loss cost. The amounts $f$, $W$, $L$, and net are transferred separately to the fee-collector, wheeling, loss, and seller accounts respectively. The zone parameters are interpreted in bps, namely $m = m_("bps") slash 10000$ and $w = w_("bps") slash 10000$, where the default wheeling charge equals 0 intra-zone and 0.02 cross-zone, while the loss factor equals 1.01 intra-zone and 1.03 cross-zone.

To illustrate the use of the equations above, consider an example of intra-zone matching with sell ask price $p_s = 4.00$ baht per kWh, quantity $q = 10$ kWh, and the intra-zone defaults ($lambda = 1.01$, $w = 0$, $m = 1$, $delta = 0.95$, $phi = 25$ bps). From @eq:loss-cost we obtain $c_("loss") = 4.00(1.01 - 1) = 0.04$, and from @eq:clearing the clearing price $p^* = (4.00 + 0 + 0.04) dot 1 dot 0.95 = 3.838$ baht per kWh, which can be matched when the buy bid price $p_b >= 3.838$. The total value is then $V = 10 dot 3.838 = 38.38$ baht, the fee $f = 38.38 dot 25 slash 10000 approx 0.096$ baht, the total wheeling charge $W = 0$, and the total loss cost $L = 10 dot 0.04 = 0.40$ baht, giving the seller a net amount of $"net" = 38.38 - 0.096 - 0 - 0.40 approx 37.88$ baht. The actual computation in the code uses floor-rounded fixed-point integers, so the resulting values may differ from this example at the rounding-fraction level.

The token pricing mechanism at the treasury layer covers the exchange between GRX and the THBC stablecoin pegged to the baht, using the rate $r$ (number of GRX atoms per THBC) and the swap fee $psi$ (bps)
$ "thbc" &= (g dot r) / 10^9 dot (1 - psi slash 10000) #<eq:swap> \
  g &= ("thbc" dot 10^9) / r #<eq:redeem> $
where redemption per @eq:redeem incurs no fee, and the peg is maintained using a 1:1 supply-to-reserve condition, namely $"supply"_("thbc") <= "reserve"_("attested")$. Staking rewards use a MasterChef-style accumulator, where a staker's accrued reward is computed from the staked amount $s$
$ "reward" = s dot A slash 10^12 - "debt" $ <eq:reward>
When a reward $R$ is funded, the accumulator $A$ is updated to $A <- A + (R dot 10^12) slash s_("total")$ pro-rata by stake share, and a slash deducts the requested amount but not more than the staked principal (capped at principal), then redistributes it back to the remaining stakers through the same accumulator.

On the production CDA path, the incentive multiplier is set to $m = 1$; that is, the incentive multiplier takes effect only on the feed-in or grid-export settlement path, not on CDA matching. In addition, the on-chain default of the market fee (25 bps) differs from the default in the off-chain configuration file (50 bps), and the zone parameters in the governance program are stored at ×1000 scale, while the consumer of the actual values in the trading layer interprets them in bps ($slash 10000$), which is the value the system actually uses. The computation in the code uses floor-division fixed-point integers, and the seller net uses checked arithmetic that rejects a transaction when the total fees exceed the matched value (with a network fee ceiling of 20%) instead of clamping the amount down to zero. Therefore the equations above constitute a real-value model that may differ from the actual computed result at the rounding-fraction level.

== Sensitivity of Seller Net and P2P Trading Uplift <sec:revenue-sensitivity>
To show the economic implications of the pricing model above, this section analyzes the sensitivity of the seller's net amount to the zone parameters and the fee. This is a purely model-derived computation from the settlement equations in @eq:clearing and @eq:net, not a measurement of revenue from running the real system. We fix the base sell ask price $p_s = 4.00$ baht per kWh, the matched quantity $q = 10$ kWh, and the incentive multiplier $m = 1$ (per the real CDA path), then vary the intra-zone/cross-zone state, the fee rate $phi$, and the loss factor $lambda$ as in @tbl:revenue-sensitivity.

#figure(
  caption: [Model-derived seller-net sensitivity computed from @eq:clearing and @eq:net at $p_s = 4.00$ ฿/kWh, $q = 10$ kWh, $m = 1$. "net" is the seller's settled amount; wheeling ($w$) and loss ($lambda$) are pass-through to the buyer via the landed price $p^*$.],
  text(size: 8pt)[
    #show math.equation: set text(size: 8pt)
    // Each scenario is computed from the settlement equations — never hand-typed —
    // so the table cannot drift from the model. m = 1 on the CDA path.
    #import "../metrics.typ": pricing
    #let scen(name, lambda, w, delta, phi) = {
      let ps = pricing.ps
      let q = pricing.q
      let closs = ps * (lambda - 1)            // eq:loss-cost
      let pstar = (ps + w + closs) * delta     // eq:clearing (m = 1)
      let value = q * pstar                    // eq:value
      let fee = value * phi / 10000            // eq:fee
      let wheel = q * w
      let loss = q * closs
      let net = value - fee - wheel - loss     // eq:net
      (name, delta, w, lambda, phi, pstar, net, net / q)
    }
    #let rows = (
      scen([S1 intra-zone], 1.01, 0.0, 0.95, 25),
      scen([S2 cross-zone], 1.03, 0.02, 1.0, 25),
      scen([S3 intra-zone, high fee], 1.01, 0.0, 0.95, 100),
      scen([S4 cross-zone, high loss], 1.05, 0.02, 1.0, 25),
    )
    // Guard: S1 must reproduce the worked example in @sec:pricing-model (37.88 ฿).
    #assert(
      calc.round(rows.at(0).at(6), digits: 2) == 37.88,
      message: "revenue table S1 drifted from the worked example (37.88 ฿)",
    )
    #table(
      columns: 8,
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon,) + (center + horizon,) * 7,
      table.header(
        [Scenario], [$delta$], [$w$], [$lambda$], [$phi$ (bps)],
        [$p^*$], [net (฿)], [net/kWh],
      ),
      ..rows.map(r => (
        r.at(0),
        [#calc.round(r.at(1), digits: 2)],
        [#calc.round(r.at(2), digits: 2)],
        [#calc.round(r.at(3), digits: 2)],
        [#calc.round(r.at(4))],
        [#calc.round(r.at(5), digits: 3)],
        [#calc.round(r.at(6), digits: 2)],
        [#calc.round(r.at(7), digits: 2)],
      )).flatten(),
    )
  ],
) <tbl:revenue-sensitivity>

From @tbl:revenue-sensitivity, two important patterns are visible. First, the seller's net amount barely changes when the wheeling charge $w$ or the loss factor $lambda$ is increased (compare S2 with S4, which differ at the level of fractions of a satang), because both costs are added into the landed price $p^*$ paid by the buyer and then split off to the wheeling-collector and loss accounts. They are therefore pass-through costs that do not directly reduce the seller's amount, so the seller always receives an amount close to $q dot p_s$. Second, the variables that significantly affect the seller's amount are the intra-zone discount $delta$ and the fee rate $phi$: intra-zone matching ($delta = 0.95$) reduces the seller's amount by about 5% to incentivize local consumption, while raising the fee from 25 to 100 bps (S1 → S3) reduces the net amount only slightly.

Compared with a flat feed-in tariff for surplus power under a hypothetical citizen-solar program assumed at around 2.20 baht per kWh, the seller's per-unit net amount in the P2P market (approximately 3.76–3.99 baht per kWh) represents an uplift of about 72–81%. At the same time, the buyer still pays a landed price $p^*$ (approximately 3.84–4.22 baht per kWh) lower than the usual retail electricity price, so gains from trade arise on both sides. Here the 2.20-baht purchase rate is merely a hypothetical reference value for comparison, not a value measured from a real market.

A limitation of this analysis is that the numbers in @tbl:revenue-sensitivity are model-derived results under fixed parameters and a single matched quantity (10 kWh). Moreover, the actual computation in the code uses floor-rounded fixed-point integers, so the resulting values may differ at the rounding-fraction level, and this is not yet a measurement of revenue distribution under a full-scale simulated workload, which is left as future work (see @sec:discussion_limitations).

== Continuous Double Auction Matching <sec:cda-matching>
The market mechanism uses Continuous Double Auction (CDA) matching that orders by price-time priority and accounts for the topological constraints of the power network. Sell orders are partitioned into a zone-segmented order book, where each zone stores sell orders in an ordered structure (BTreeMap) keyed by `(price, created_at, id)`, so that the key ordering prioritizes the lowest price first, then the earlier order-creation time, and uses the order id as the final tie-breaker, thereby yielding price-time priority implicitly without re-sorting. Orders whose remaining quantity falls below the minimum threshold (MIN_TRADE_AMOUNT) or that have expired are not inserted into the book.

For each buy order, the matching engine gathers candidate sellers only from zones from which the network can deliver energy to the buyer's zone, via two-stage topology pre-filtering: the first stage checks at the minimum quantity to immediately exclude zones that cannot reach each other, and the second stage re-checks at the actual matched quantity (`can_accommodate_flow(sell_zone, buy_zone, amount)`) to enforce the transmission-line capacity ceiling. Within each reachable zone, a range query is used to retrieve only sell orders whose ask price does not exceed the bid price, then the landed cost is computed per @eq:clearing (including wheeling, loss cost, multiplier, and the intra-zone discount $delta = 0.95$). Only sell orders whose landed cost does not exceed the bid price ($p^* <= p_b$) pass through as candidates. The system prevents self-trade by skipping pairs where the buyer and seller are the same user.

Once candidates from all reachable zones are obtained, the system consolidates the list and sorts by landed cost from low to high, so the buyer gets the cheapest landed total price first, regardless of which zone that sell order is in. It then matches progressively, with the per-pair quantity equal to the smaller remaining amount of the two sides ($q = min(q_b, q_s)$) as a partial-fill, and immediately removes sell orders whose remaining quantity falls below the threshold from the book. For Fill-or-Kill (FOK) buy orders, the system first checks whether the total candidate quantity is sufficient for the entire order; if not, it does not match at all. In addition, there is match consolidation when the same buyer-seller pair and the same price occur consecutively, to reduce the number of settlement records that must be sent on-chain. Each match result records the match price (landed cost), wheeling charge, loss cost, and source/destination zones, before sending the matched pairs to atomic settlement per @sec:settlement-model. The on-chain processing cost of the settlement path fed by the matching engine is reported in @sec:settlement-cost, while the matching throughput of the matching engine in the in-memory layer is reported in @sec:matching-throughput.
