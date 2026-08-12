#import "@preview/cetz:0.5.2"
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge, shapes

= SETTLEMENT MODEL <sec:settlement-model>

_The central thesis: cleanly split off-chain verification from on-chain settlement, so the chain records only verified matches and enforces correctness invariants at every step — the value is the composition, not any single part._


== Architecture Overview
This work partitions responsibility into two interconnected trust domains joined through a single point. The off-chain trust domain performs validation and matching: it comprises the metering layer (a Smart Meter Simulator following the AMI standard and DLMS/COSEM) that feeds data into the Aggregator Bridge to verify Ed25519 signatures and screen the data, before forwarding it to the Trading Service, which matches orders using the Continuous Double Auction (CDA) algorithm, with the IAM Service and Notification Service supporting identity and notification. The on-chain trust domain settles transactions and records evidence: it comprises a set of Anchor programs (registry, trading, oracle, energy-token, governance, and treasury) on a permissioned (consortium) Solana-compatible network that records state into PDA accounts and an event log.

The crossing from the off-chain domain to the on-chain domain occurs solely through the Chain Bridge, the only service that contacts Solana RPC directly. It receives write commands over NATS JetStream and serves state reads over ConnectRPC on a channel protected by mTLS. The on-chain programs are Anchor programs @anchorDocs running on the Solana Virtual Machine (SVM) @yakovenkoSolanaWhitepaper and use Program Derived Addresses (PDA) to create accounts whose ownership is deterministically verifiable. Separating the two domains in this way means that power-engineering validation and access control happen before a transaction is recorded, while the blockchain serves as a thin settlement and audit layer. The full details of the services, their connectivity, and the architecture diagram appear in @sec:system-architecture. This article is an architectural evaluation on a simulated system, not a measurement from a production Solana network.

== Settlement Model
The settlement model separates responsibility into two layers with clearly distinct trust boundaries. The off-chain layer performs validation and matching: it comprises the Aggregator Bridge, which verifies the Ed25519 signatures of meter readings, checks the data format against the DLMS/COSEM standard, and evaluates available-surplus conditions together with grid stability; and the Trading Service, which matches buy/sell orders using the Continuous Double Auction (CDA) algorithm. The output of this layer is a validated order pair together with an order payload signed by both parties. The on-chain layer is an Anchor program @anchorDocs that acts as a thin settlement and audit layer, accepting only validated order pairs and recording an auditable result.

Before recording a settlement, the on-chain program enforces only conditions that are verifiable from the payload and account state, namely: account-ownership checks, the Ed25519 signatures of both buyer and seller on the order payload, double-submission prevention via the order nullifier account, and the validity of the escrow state. Conditions that require external data, such as available surplus and oracle attestation, are enforced in the off-chain layer before submission and are not re-checked on-chain. This division of responsibility means the blockchain need not directly trust external data, yet can confirm that every settlement originates from an order pair genuinely signed by both parties. All account structures use Program Derived Addresses (PDA) to isolate the state of each transaction and to verify ownership deterministically. The details of the programs and PDA accounts are described in @sec:smart-contract-programs @solanaPdaDocs.

== Atomic Delivery-versus-Payment
A matched order pair is settled through the `settle_offchain_match` instruction of the trading program, which operates as delivery-versus-payment (DvP) within a single transaction; that is, the transfer of funds and the transfer of energy happen together or not at all. If any transfer fails, the entire transaction is reverted, so there is no lingering state in which one party has received while the other has not. Before the transfer, the program checks the Ed25519 signatures of both the buyer (instruction sysvar index 0) and the seller (index 1) over a message that binds the order's key fields, namely order_id, user, energy_amount, price_per_kwh, side, zone_id, and expires_at, making it impossible to alter the amount or price after signing. It then checks the price-crossing condition, namely that the match price must lie within the range $p_s <= p^* <= p_b$, checks the side of both parties, and checks the expiry time.

Settlement is partial-fill: the order nullifier account (seed `[nullifier, user, order_id]`) stores the accumulated filled amount (filled_amount) instead of a boolean value, so an order can be filled multiple times up to the signed amount, but the total will not exceed that amount ($"match" <= "energy_amount" - "filled"$) on either side. For cross-zone transactions that use inter-zone transmission lines, the program additionally enforces a cap on the accumulated committed flow on-chain ($"committed_flow" + "match" <= "capacity"$), whereas transactions within the same zone are exempt because they do not use inter-zone transmission lines. Once all conditions pass, the total value and the shares are computed as follows, with currency flowing from the buyer escrow to the fee/wheeling/loss collectors and the seller escrow, and energy (energy token) flowing from the seller escrow to the buyer escrow. All transfers out of the escrow accounts are signed by the market_authority PDA as the owner of the escrow accounts (signing the token-transfer CPI), while authorization of the settlement comes from the Ed25519 signatures of the buyer and seller as described above. Besides the single-match instruction, the program also has a batch settlement instruction (`batch_settle_offchain_match`) that can combine up to 4 pairs per transaction to reduce cost, using the very same set of validation conditions (Ed25519 signatures, order nullifier, price crossing, and the cross-zone flow cap), and binding accounts from the signed payload by checking the Program Derived Address (PDA) of every account passed in.

The escrow structure just described — one escrow PDA per party, address-bound to the signed payload — is the model this section analyzes and the one the `settle_offchain_match` and `batch_settle_offchain_match` instructions implement. The program also carries a second, custodial settlement entry point (`execute_atomic_settlement`) whose escrows are pooled token accounts owned by the platform key rather than by the parties, and it is that path the prototype deployment currently calls (see @sec:trading-program). Every invariant stated below concerns the non-custodial path; on the custodial path the invariants that derive from *address binding* — that an attacker cannot substitute a victim's escrow, and that authority to disburse is a property of the code path rather than of a key an operator holds — are replaced by trust in the platform key, while the invariants enforced from the *payload* (both signatures, the nullifier, price crossing, the flow cap, the checked value split) continue to hold unchanged.

$ V &= "match" dot p^* #<eq:settle-value> \
  "fee" &= floor(V dot phi slash 10000) #<eq:settle-fee> \
  "net"_s &= V - "fee" - w - c_("loss") #<eq:settle-net> $

This set of equations is the on-chain rounded-down integer (fixed-point) form of @eq:value through @eq:net in @sec:pricing-model, where $V$ is the total value leaving the buyer escrow, $phi$ is the market fee (market_fee_bps), $w$ is the wheeling charge, $c_("loss")$ is the loss cost (see @eq:loss-cost), and $"net"_s$ is the seller's net amount. All computations use checked arithmetic instead of clamping values; that is, the value multiplication rejects the overflow case, and the deduction of the seller's net will *reject* the transaction (require! with error `ChargesExceedValue`) when the sum of the fee, wheeling and loss exceeds the value $V$, instead of rounding the amount down to zero, together with a cap on the total network fees of no more than 20% of $V$. When the market is configured to settle in THBC, the system enforces recording the gross value through the `record_settlement` CPI to the treasury program, so that the settlement counter reconciles against the actual cash flow leaving escrow.

== Discovery Path and Settlement Path <sec:two-paths>
The trading program exposes two families of instructions that are easily mistaken for one another, and the distinction is central to reading the rest of this section. The *discovery path* — `match_orders`, `clear_auction`, `submit_limit_order` — operates on the on-chain order book: it establishes which orders pair with which, at what price, and records the outcome. It moves no tokens. The *settlement path* — `settle_offchain_match` and `batch_settle_offchain_match` — is the only path in the system that moves value, and it accepts pairs that were matched *off-chain* and signed by both parties. @tbl:two-paths contrasts them.

#figure(
  caption: [The two instruction families of the trading program. Only the settlement path moves tokens; the discovery path produces an on-chain record of a match, not a transfer. The two also differ in what they trust: the on-chain book versus a pair of Ed25519 signatures over off-chain orders.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6pt)
    #table(
      columns: (auto, 1fr, 1fr),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (left + horizon, left + horizon, left + horizon),
      table.header([], [discovery path], [settlement path]),
      [instructions], [`match_orders`, `clear_auction`, `submit_limit_order`], [`settle_offchain_match`, `batch_settle_offchain_match`],
      [writes], [`Order`, `TradeRecord`, zone book depth], [escrow transfers, `TradeNullifier`, `ZoneCapacity`],
      [moves tokens], [no — the recorded value is informational], [yes — the only value-moving path],
      [trust anchor], [the on-chain order book], [Ed25519 signatures on off-chain orders],
    )
  ],
) <tbl:two-paths>

Because the two paths coexist, the same quantity is represented at two different scales, and this dual-scale contract must be stated explicitly to avoid misreading either the code or the events it emits. On the discovery path, `TradeRecord.total_value` is the raw product of amount and price with *no* rescaling by the nine-decimal energy divisor, because it is a discovery artifact that no transfer consumes. On the settlement path the same product *is* rescaled, because it becomes an actual currency movement. Conflating the two would inflate a settled amount by a factor of $10^9$, and the on-chain auction verifier depends on the raw scale being preserved on the discovery side, so neither representation can simply be normalized to the other. The dual scale is therefore a contract between the two paths rather than an inconsistency, and it is documented as such at both ends.

The pricing rules of the two paths also differ, and both are correct within their own scope. The on-chain `match_orders` instruction clears at the *resting sell price*: given a crossing pair, the clearing price is the seller's ask, so any price improvement accrues to the buyer rather than being split at the midpoint. Its only admission test is the crossing condition $p_b >= p_s$. The off-chain matching engine, by contrast, clears at the landed cost $p^*$ of @eq:clearing, which folds in wheeling, losses and the incentive multiplier (@sec:pricing-model) — a richer rule that the on-chain book deliberately does not attempt to reproduce. The batch alternative `clear_auction` computes supply and demand curves and their intersection to give one uniform clearing price for an entire batch, but it likewise defers all token movement to the settlement path.#footnote[The uniform-auction instruction pair is implemented and tested but has no on-chain, test, or client caller in the evaluated configuration; the live path is continuous double-auction matching off-chain followed by `settle_offchain_match`. We report it as available design surface, not as a measured mechanism.]

Orders themselves carry an explicit lifecycle. An order is created `Active`, becomes `PartiallyFilled` once any quantity settles against it, and reaches `Completed` when the cumulative filled amount meets the order quantity, at which point the zone book's active-order count is decremented; `Cancelled` and `Expired` are the two terminal states reached without full execution. The filled amount is monotonically non-decreasing and the remaining quantity is always the order amount less that filled total, which is what makes partial fills safe to apply repeatedly (@sec:settlement-model).

== The Settlement Pipeline <sec:settle-pipeline>
The settlement instruction executes a fixed, ordered pipeline in which every stage is a rejection point: no state is written and no token moves until all checks have passed, and any failure reverts the entire transaction. The order of the stages is itself a design decision — the cheapest and most security-critical checks run first, so a forged or replayed settlement is rejected before any compute is spent on token arithmetic.

The first stage verifies both parties' Ed25519 signatures through the instruction sysvar, with the buyer's verification instruction at index 0 and the seller's at index 1, each over the 77-byte canonical message of @sec:wire-formats. The second bounds the economics: the match price must not exceed the buyer's signed limit nor fall below the seller's, both parties' declared sides must be correct, and neither order may have expired. The third stage applies the transmission constraint, but only for cross-zone matches — the committed flow on the inter-zone `ZoneCapacity` account is incremented and checked against the zone's capacity, while an intra-zone match does not touch that account at all. The fourth stage is the two-layer replay guard: the per-order nullifier caps the cumulative filled quantity on each side, and the per-match `TradeNullifier` account is created atomically with the settlement, so a re-sent match — one re-signed with a fresh blockhash, which would defeat a transaction-hash-based deduplication upstream — fails on an already-existing account even when the underlying orders still have unfilled headroom.

Only then does the fifth stage compute the charge waterfall. Writing $q$ for the matched quantity in nine-decimal energy units, $p^*$ for the match price, and $D = 10^9$ for the energy scale divisor:

$ V &= floor(q dot p^* slash D) #<eq:onchain-value> \
  f &= floor(V dot phi slash 10000) #<eq:onchain-fee> \
  W &= floor(q dot r_w slash D) #<eq:onchain-wheeling> \
  L &= floor(V dot ell slash 10000) #<eq:onchain-loss> \
  "net"_s &= V - f - W - L #<eq:onchain-net> $

Two asymmetries here are easy to miss and both are deliberate. The wheeling charge $W$ is computed from a *flat per-kWh rate* $r_w$ scaled by the energy divisor, not as basis points of the trade value, whereas the market fee $phi$ and the loss factor $ell$ *are* basis points of value. And both $r_w$ and $ell$ are read directly from the on-chain `TariffConfig` account rather than taken from the caller's arguments, so a submitting operator cannot inject a tariff of its choosing; the account is passed as a mandatory trailing account and its bytes are validated and decoded in place. Two guards then bound the result: the network charges $W + L$ may not exceed 20% of $V$, and the total deductions may not exceed $V$ at all. Both are hard rejections rather than saturating subtractions — an earlier formulation clamped the arithmetic and could silently pay the seller zero, which is precisely the failure mode that a rejection makes impossible.

The sixth stage performs the transfers, and it is worth noting that three distinct assets move, at three different scales and in two directions. Currency (six decimals) flows out of the buyer's escrow to the fee, wheeling, and loss collectors and then to the seller for the net amount, with each zero-valued leg skipped. Energy (nine decimals, kWh scaled by $10^9$) flows in the opposite direction, from the seller's energy escrow to the buyer's. Where the renewable attribute is being conveyed, an optional REC leg moves from the seller to the buyer at 1,000 base units per kWh, reflecting a six-decimal REC mint against nine-decimal energy. The seventh and final stage records the settlement in the treasury: for markets configured to settle in THBC, the invocation carries the *gross* value and is mandatory — omitting the treasury accounts is rejected rather than silently skipped, so the treasury's settled total cannot drift below the cash that actually left escrow.

== Write-set Structure and Parallel Execution <sec:write-set>
Because Solana schedules transactions in parallel whenever their write sets are disjoint, what a settlement *write-locks* determines how many settlements can proceed concurrently. The design pushes every hot write onto a per-entity account: orders live at a PDA derived from the owner and order identifier, each match creates its own nullifier, and per-zone volume accumulates into shard accounts rather than into the zone book.

The sharpest instance of this discipline is the treatment of the zone market account. Capacity and zone identity are *read* from it on every settlement, but the mutable committed-flow counter lives on a separate `ZoneCapacity` account that is passed as a mutable account only on the cross-zone path. An intra-zone settlement — the common case, since local matching is what the market's discount is designed to encourage — therefore never write-locks the shared zone book, and any number of intra-zone settlements in the same zone remain mutually parallelizable. Had the counter stayed on the zone market account, every settlement in a zone would have serialized on it regardless of whether it used an inter-zone line at all. The per-shard accumulators are drained into the zone book by a separate administrative reconciliation instruction, which is off the hot path by construction. What remains genuinely serial is the treasury's central settled total and the collector accounts, which every settlement must write — and that, rather than any property of the shards, is the bottleneck the throughput measurement in @sec:onchain-throughput reports.

== Authorization to Settle <sec:settle-authz>
A final gate governs *who* may submit a settlement at all. The transaction's fee payer must correspond to an active, governance-admitted aggregator entry, validated by the same read-only pattern described in @sec:cpi: owner check, canonical PDA derivation, and in-place decoding of the entry's bytes. Settlement is consequently not self-serviceable — possessing two validly signed orders is not sufficient to settle them; the submitting operator must itself be admitted by the consortium's governance layer. Zones additionally carry a market segment, and a wholesale zone requires the submitting aggregator to hold wholesale admission specifically, whereas retail zones accept any admitted aggregator. Entries predating the segment field default to retail rather than failing, so the field could be introduced without invalidating operators already admitted. This closes the loop between the on-chain settlement mechanics described above and the consortium governance model of @sec:consortium-network: the cryptographic checks establish that a trade was genuinely agreed by both parties, and the admission check establishes that a licensed party is the one recording it.

== Consensus
The system's smart contracts are Anchor programs running on the Solana Virtual Machine (SVM). The ordering and consensus of transactions are therefore the responsibility of the Solana-compatible network on which the programs are deployed, and are not defined or tuned at the program level. The platform's consensus mechanism is split into two cooperating parts, namely Proof of History (PoH), a cryptographic verifiable clock that orders events in time before voting, and Tower BFT, a Byzantine Fault Tolerant voting mechanism developed from the Practical BFT (PBFT) @castro1999practical concept to confirm blocks and declare block finality @yakovenkoSolanaWhitepaper.

In this work's evaluation, the Anchor programs are run on an SVM-level test environment (LiteSVM) and a single-node validator (localnet) to verify correctness and measure the compute-unit cost of the settlement path (see @sec:settlement-cost). Consequently, consensus properties such as leader selection, validator voting, and multi-node finality time are platform properties that are not measured in this work. The control of participation rights and consortium governance is a program-level governance layer separate from network-level consensus; details are in @sec:consortium-network.

== Block and Settlement Transaction Structure <sec:tx-structure>
Because the programs run on a Solana-compatible network, the block structure and block header follow the platform's definition and are not tuned at the program level. Each block is bound to a slot with a target of approximately 400 milliseconds (see @sec:consortium-network). The order of transactions within is determined by the Proof of History (PoH) sequence before voting with Tower BFT, while each transaction references the latest blockhash to set its lifetime and prevent replay at the transaction level. These structures are platform properties @yakovenkoSolanaWhitepaper, so this work emphasizes the structure of the settlement transactions that the program designs itself, rather than the block format. A block chain linked by previous blockhash is shown in @fig:block-structure.

#figure(
  text(size: 6.5pt)[
    #cetz.canvas(length: 1cm, {
      import cetz.draw: *
      let blue = rgb("#5b7aa8")
      let orange = rgb("#c77d3c")
      let gray = rgb("#888888")
      let hl = rgb("#3c6fa0")
      // top chain: five consecutive blocks, slots N−2 … N+2
      let bw = 1.1
      let xs = (0, 1.5, 3.0, 4.5, 6.0)
      let labels = ([N−2], [N−1], [N], [N+1], [N+2])
      for (i, x) in xs.enumerate() {
        let focus = i == 2
        rect((x, 2.0), (x + bw, 2.9), radius: 0.05,
          stroke: (if focus { 0.8pt + hl } else { 0.5pt + gray }),
          fill: (if focus { rgb("#eef3fb") } else { luma(247) }))
        content((x + bw / 2, 2.62), text(6pt, weight: "bold", fill: (if focus { hl } else { gray }))[slot #labels.at(i)])
        content((x + bw / 2, 2.31), text(4.6pt, fill: gray, raw("blockhash")))
      }
      // previous_blockhash links — each block references its predecessor
      for i in range(4) {
        line((xs.at(i + 1), 2.3), (xs.at(i) + bw, 2.3), mark: (end: ">", scale: 0.4), stroke: 0.4pt + gray)
      }
      content((3.55, 3.12), text(5pt, fill: gray, raw("previous_blockhash") + [ ←]))
      // zoom from focus block (slot N) down to its detailed view
      let dx0 = 0.8
      let dx1 = 5.3
      let cx = (dx0 + dx1) / 2
      line((3.0, 2.0), (dx0, 0.97), stroke: (paint: hl, dash: "dashed", thickness: 0.4pt))
      line((3.0 + bw, 2.0), (dx1, 0.97), stroke: (paint: hl, dash: "dashed", thickness: 0.4pt))
      rect((dx0, -2.5), (dx1, 0.97), radius: 0.08, stroke: 0.7pt + blue)
      rect((dx0, 0.0), (dx1, 0.97), stroke: 0.4pt + blue, fill: rgb("#eef3fb"))
      content((cx, 0.74), text(6.5pt, weight: "bold", fill: blue)[Block Header · slot N])
      content((cx, 0.46), text(5.2pt, raw("previous_blockhash") + [ · ] + raw("parent_slot")))
      content((cx, 0.18), text(5.2pt, raw("blockhash") + [ (PoH) · tick height]))
      content((cx, -0.22), text(6pt, weight: "bold")[Transactions — ordered by PoH])
      content((cx, -0.52), text(5.2pt, fill: gray)[• transfer / create-order tx …])
      rect((dx0 + 0.15, -1.02), (dx1 - 0.15, -0.62), radius: 0.04, stroke: 0.5pt + orange, fill: rgb("#fbf0e6"))
      content((cx, -0.82), text(5.2pt, fill: orange.darken(25%), raw("settle_offchain_match") + [ (settlement)]))
      content((cx, -1.24), text(5.2pt, fill: gray)[• other mint / settle tx …])
      content((cx, -2.26), text(5.2pt, fill: gray)[PoH ordering → Tower BFT finality])
    })
  ],
  caption: [Block structure on a Solana-compatible network (defined by the platform, not tuned at the program level): a continuous chain of blocks (slot N−2 to N+2) in which each block references its predecessor through previous blockhash. Below, slot N is expanded; the block header contains the blockhash derived from PoH and parent_slot, while the transactions within, including the `settle_offchain_match` settlement instruction (see @sec:tx-structure), are ordered by Proof of History before finality is declared by Tower BFT.],
) <fig:block-structure>

Because the block format is what a settlement is ultimately recorded into, and because it differs fundamentally from the mined-block model most readers carry, it is worth stating precisely what a block is on this platform. A block is not a fixed data structure with a proof-of-work header; it is the ordered sequence of *entries* that the slot's leader streams during one time-boxed slot. There is no nonce, no difficulty target, and no mined Merkle root, and the value called the "blockhash" is simply the last Proof-of-History hash produced during the slot — a timestamp and ordering value, not a hash of a header.

A slot is a *time* box rather than a *size* box: a fixed window of approximately 400 milliseconds, numbered monotonically so that the slot number is also the block height. It ends when the time elapses, whether the leader filled it, half-filled it, or produced nothing — an offline leader simply yields a skipped slot, and the chain builds on the last real block. This is the opposite of a size-capped, proof-of-work-timed block that arrives whenever a puzzle is solved. Which node leads which slot is not decided by an election at slot time: the leader schedule for an entire epoch is computed locally by every node, deterministically and weighted by stake or, in this system's permissioned setting, by admitted authority, before the epoch begins. No messages are exchanged to discover the leader of slot $N$ — every node has already looked it up. This is the second latency saving after PoH itself: where a classical Byzantine-fault-tolerant protocol spends a message round choosing a proposer, this platform spends none.

The unit a block is built from is the entry, which carries the number of PoH hashes elapsed since the previous entry, the PoH hash value at that point, and a vector of zero or more transactions pinned at that hash. An entry with no transactions is a *tick* — pure advancement of the verifiable clock at a fixed number of hashes per tick, keeping time moving even when there is no traffic — while an entry with transactions fixes their order by mixing them into the hash chain at that point. When the configured number of ticks per slot is reached, the slot ends. A block is therefore the entry list for its slot, and replaying it reconstructs two proofs from one stream: the PoH chain establishes time and order, and re-executing the transactions establishes the resulting state.

The Proof-of-History clock underneath has a deliberate asymmetry that matters for a permissioned deployment. A tick is a fixed number of sequential SHA-256 iterations, each hashing the previous output, and a slot is a fixed number of ticks — so a slot is a fixed quantity of strictly sequential single-core hashing, on the order of 400 milliseconds. Producing it is inherently serial and $O(N)$ in the hash count: the leader must compute every hash in order, because that sequentiality *is* the clock and cannot be parallelized away. Verifying it, by contrast, is parallel: because the leader publishes the hash value at each tick checkpoint, a verifier can split the chain at those checkpoints and hand each segment to a different core, each recomputing its segment from the published starting hash and confirming it reaches the published ending hash. With $K$ cores a block verifies roughly $K$ times faster than it was produced. A transaction mixed in at a given tick is thereby provably ordered after the previous checkpoint and before the next, giving a time resolution of one tick.

What `getBlock` returns as block metadata reflects this model rather than a mining header: the slot and block height give position, the blockhash is the slot's final PoH hash, the previous blockhash and parent slot link to the block built upon (which may skip empty slots), and the block time is an estimated wall-clock instant derived from PoH together with validators' clocks. Acceptance then separates three concerns that a proof-of-work chain fuses into one: ordering is already given by PoH, validity is checked by replaying the transactions and recomputing the bank hash (a mismatch rejects the block), and finality is voted by Tower BFT with stake-weighted votes until the block is rooted. Because production optimistically streams entries before finality, two valid blocks can briefly coexist on competing forks; Tower BFT roots one and prunes the other. This three-way separation — order, then validity, then finality — is precisely the property the settlement design leans on, since it lets the program treat the blockhash as an ordering-and-recency token independent of the vote that will later finalize it.

That recency role is the one place the block model surfaces directly in the application. Every transaction carries a recent blockhash — a recent slot's final PoH hash — and the runtime rejects any transaction whose blockhash is older than roughly 150 slots, about a minute. This is why the throughput harnesses of @sec:onchain-throughput fetch a fresh blockhash immediately before sending and re-fetch it when re-firing a dropped transaction: a settlement built against a stale blockhash is rejected before it executes, independent of whether its contents are valid. The programs' own notion of time — the oracle's fifteen-minute clearing windows and an order's expiry — is read through the runtime clock, whose value traces back to this same PoH stream.

Two caveats bound how much of this the present work exercises, and they are the same as elsewhere. The evaluated configuration is a single-node permissioned localnet: PoH runs, entries pack into blocks, and block time advances, but the node self-produces with no voting quorum, so leader rotation, fork choice, and Tower BFT finality are never triggered in development or test (the same limitation noted for consensus in @sec:consortium-network). The mainnet-state simulation used elsewhere runs against forked state with no local validators at all. Real Tower BFT among several operator-run validators is the target deployment and is outside the scope measured here.

A single settlement transaction comprises one settle instruction together with two Ed25519 signature-verification instructions per matched pair (for the buyer and the seller) that the program verifies through the instruction sysvar, where the signature payload (signature, public key and the canonical message, totaling about 189 bytes per instruction) resides in the instruction data, not in the accounts, so the address lookup table (ALT), which compresses only the account list, cannot reduce the size of this part. For this reason, even though the program permits batch settlement of up to 4 pairs per transaction (`batch_settle_offchain_match`), the practical cap is constrained by the 1,232-byte transaction packet size: combining two pairs (4 signature-verification instructions at about 760 bytes, together with the serialized BatchMatchPair at about 370 bytes, plus the account index list and header) already exceeds the packet size. Increasing the actual number of pairs per transaction therefore requires changing how the signatures are packed (for example, pre-verified signature accounts, or an off-chain aggregated multisig), not merely increasing the number of pairs. The accounts the transaction touches comprise the buyer's and seller's escrow accounts, the order nullifier accounts of both sides, the zone_market account, and the fee/wheeling/loss collector accounts in the treasury. This structural constraint explains why the batching cap and the throughput of settlement are tied to the transaction format, which is consistent with the measurement results in @sec:onchain-throughput. The exact byte layouts behind these figures are given in @sec:wire-formats.

== The Transaction as a Signed Message <sec:tx-anatomy>
The byte budget of the previous section is best understood from the shape of the transaction itself, because the scheduling behavior, the packet wall, and the one-match batch cap all fall out of how a transaction packs its accounts and its instruction data. A transaction is a list of 64-byte signatures over a single serialized *message*, and the message is where all the structure lives: a three-byte header, a flat ordered array of account public keys, the recent blockhash, and a list of compiled instructions. Each compiled instruction does not repeat public keys — it names its program and its accounts by *index* into the shared account array, and carries only its own opaque data. That shared, indexed account array is precisely what lets the runtime compute a transaction's write-lock set cheaply, which is what Sealevel schedules on (@sec:write-set).

The header does more than count: privilege in this model is *positional*. The account array is ordered in four contiguous classes — writable signers, read-only signers, writable non-signers, read-only non-signers — and the header's three counts are the boundaries that slice the array into them. Whether an account is a signer and whether it is writable is therefore derived from *where it sits* in the array, not from a per-account flag, and the first signer is by convention the fee payer. The recent blockhash field is the transaction's time-to-live and its replay guard at once: it must name a slot within roughly the last 150, or the transaction is rejected as stale (@sec:tx-structure), and because it is bound into the signed message a captured transaction cannot be hoarded and replayed later. This is why the harnesses of @sec:onchain-throughput fetch a fresh blockhash immediately before every send and again before every re-send.

Two mechanisms in the settlement transaction deserve to be named at this level, because they are what make the design's security rest on structure rather than on trust. The first is that the Ed25519 verification of each signer is *not* a cross-program invocation but a separate native precompile instruction placed ahead of the program instruction; the settlement program reads those instructions back through the instructions sysvar and hand-parses their bytes — walking the sysvar's offset table to the precompile entry, skipping its account list, and lifting out the exact message the precompile verified. It then re-derives the identical 77-byte payload from its own arguments and checks the two match byte-for-byte. Signature validity is thereby established with no invocation at all, which is why the signature material sits in instruction *data* (and so cannot be compressed by an address lookup table, the fact that ultimately caps the batch at one match). The second mechanism is that every account the settlement touches must equal the canonical Program Derived Address for the *signed* payload — the buyer's nullifier must be exactly `find_program_address([nullifier, buyer, order_id])`, and so on for each escrow and collector — checked with an equality assertion. Address derivation is therefore the authorization: an attacker cannot substitute a victim's escrow to divert funds, nor an unrelated nullifier to bypass the replay guard, because the account addresses are cryptographically bound to the very order bytes both parties signed.

Finally, the stack ceiling of @sec:ceilings leaves a visible mark on the message. The accounts that ride in `remaining_accounts` to keep the validation context under 4 KB — the governance config whose maintenance byte is read without deserializing its 405-byte struct, the tariff config, the optional zone-capacity account, the treasury accounts — still occupy slots in the message's account array exactly like typed accounts; what they skip is only Anchor's stack-heavy materialization during `try_accounts`, not their place on the wire. The message pays for them in bytes either way; the stack workaround buys frame space, not packet space. Address lookup tables reclaim the byte cost of those account *keys*, but as established, they cannot touch the per-match signature data that is the binding constraint.

== Binary Data Formats and Byte Budgets <sec:wire-formats>
The preceding argument — that settlement is bound by transaction *bytes* rather than by compute — only carries weight if the byte figures are derived from the actual encodings rather than estimated. This subsection therefore states the binary layout of the data structures that dominate the pipeline's byte budget: the metering frame that crosses the trust boundary into the Aggregator Bridge, the signed order payload that authorizes an on-chain settlement, the settlement transaction that carries both, and the account frames the settlement leaves behind. All fields are given in declaration order.

Three distinct binary framings coexist on-chain, and conflating them is a source of error, so we distinguish them at the outset. (i) *Borsh*, the serializer Anchor uses for instruction arguments, events, and ordinary `#[account]` state, is little-endian and *packed*: fields follow one another with no alignment padding, variable-length fields carry a 4-byte length prefix, and every account is prefixed with an 8-byte discriminator derived from the hash of its type name. (ii) *Zero-copy* accounts, declared `#[account(zero_copy)]` with `#[repr(C)]`, are not deserialized at all — they are cast in place from the account's byte buffer on every access, which requires C layout rules, so explicit padding fields are load-bearing rather than decorative. (iii) The *signed off-chain payload* is a hand-rolled byte buffer built by concatenation, which happens to be byte-identical to Borsh for that struct because all its fields are fixed-size and appended in declaration order. The rule the system follows is that data parsed once per transaction (instruction arguments, signed messages, events) uses Borsh, whereas accounts read in place on every transaction (orders, meter state, shard accumulators) use the zero-copy form; conversions between the two — for instance a fixed `[u8; 32]` plus a length byte in state that surfaces as a `String` in an event — are always explicit, never a cast.

=== Metering Frame (Secure DLMS-lite v4)
Meter telemetry is admitted in two interchangeable encodings. The first is an OBIS-coded JSON document whose registers follow DLMS/COSEM (IEC 62056) object codes, for example `1.1.1.8.0.255` for active energy import and `1.1.2.8.0.255` for active energy export, both in Wh. The second — and the one that determines the wire cost — is a compact binary frame, "Secure DLMS-lite v4", whose layout is shown in @tbl:dlms-frame. It is deliberately parsed in two stages: the cyclic redundancy check and the plaintext header are validated *before* decryption, because the logical device name in the header is the identity used to resolve that device's key. A meter that is not known to the bridge is therefore rejected without any cryptographic work being spent on its ciphertext.

#figure(
  caption: [Byte layout of the Secure DLMS-lite v4 metering frame. The header is plaintext so that the device identity (LDN) can be resolved before decryption; the payload is an AES-256-GCM-sealed TLV block; CRC-32 covers the entire frame. Offsets are byte positions from the start of the frame; multi-byte integers are big-endian.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6.5pt)
    #table(
      columns: (auto, auto, auto, 1fr),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (center + horizon, left + horizon, center + horizon, left + horizon),
      table.header([off], [field], [B], [encoding]),
      [0], [`version`], [1], [`0x04` = v4, else reject],
      [1], [`total_length`], [1], [u8; frame size = value + 2],
      [2], [`manufacturer_id`], [3], [ASCII],
      [5], [`logical_device_name`], [8], [ASCII, NUL-padded (meter id)],
      [13], [`timestamp`], [8], [u64 BE, Unix seconds],
      [21], [TLV block], [_n_], [AES-256-GCM ciphertext],
      [—], [GCM auth tag], [16], [trailing, inside the block],
      [end−4], [`CRC-32`], [4], [u32 BE, over the whole frame],
    )
  ],
) <tbl:dlms-frame>

Three consequences follow directly from this layout. First, the header floor is 25 bytes (21 header bytes plus the 4-byte checksum), which is the smallest frame the parser will consider. Second, because `total_length` is a single byte, a frame can never exceed 257 bytes, and the sealed plaintext can never exceed 216 bytes — an upper bound on how many registers one reading may carry, enforced by the encoding rather than by policy. Third, the payload is a sequence of tag–length–value triples: energy registers carry an 8-byte big-endian value (10 bytes per triple with its 2-byte header) and the instantaneous registers carry a 4-byte value (6 bytes per triple), so a reading carrying the full five-register set (import and export energy, voltage, current, and battery state of charge) occupies 38 bytes of plaintext, 54 bytes once sealed, and 79 bytes on the wire. A verified reading is thus roughly two orders of magnitude smaller than the transaction that eventually settles the energy it represents — which is why the ingest path saturates on request handling (@sec:ingest-saturation) rather than on bandwidth.

The 96-bit GCM nonce is not transmitted; it is reconstructed on both sides as manufacturer identifier (3 bytes) $||$ timestamp (8 bytes) $||$ version (1 byte), which saves 12 bytes per frame but makes nonce uniqueness a property of the *timestamps*: because the key is per-device and the timestamp has one-second resolution, two distinct frames from the same meter within the same second would reuse a nonce. The metering layer's monotonically increasing reading times (and the oracle's minimum reading interval of 60 seconds) keep this condition satisfied in the tested configuration, but it is a design dependency worth making explicit rather than an incidental detail. Separately, the signed value is a canonical text form, `device_id:kwh:timestamp_ms`, over which the meter produces a 64-byte Ed25519 signature transmitted as 88 base58 characters; the canonical form must be byte-identical on both sides, so number formatting (integral values, negative zero, and the absence of scientific notation) is part of the protocol rather than a presentation choice.

=== The Ingest Trust Chain
The byte layout of @tbl:dlms-frame is the innermost of three layers a reading crosses on its way into the Aggregator Bridge, and the order in which those layers are applied — and unwound — is itself load-bearing. The meter first encodes the reading in the OBIS-keyed form and signs the canonical text `device_id:kwh:timestamp_ms` with its per-device Ed25519 key, so the signature covers the reading's economically meaningful value and travels *inside* the frame; authenticity is thereby established independently of how the frame is later carried. The signed frame is then sealed under AES-256-GCM with a *separate* per-device key. Two encodings of this seal coexist: the binary v4 frame of @tbl:dlms-frame derives its nonce from the manufacturer, timestamp, and version and so transmits no nonce, whereas the JSON `dlms-enc` envelope used on the REST path transmits a random 96-bit nonce explicitly and binds a monotonically increasing invocation counter into the authenticated additional data as `device_id:counter`. Replay resistance rests on that counter in two ways, and only the second actually refuses a resent frame: folding the counter into the GCM tag prevents its silent alteration, while — the operative guard — after a frame authenticates the bridge performs a stateful compare-and-set against a per-device counter it keeps in the cache tier, rejecting any value that is not strictly greater than the last accepted and advancing the stored value only on an authenticated frame. A replayed *identical* frame therefore decrypts but is refused at this step, a property distinct from the inner signature, which establishes only authenticity. This is the REST-path analogue of the binary frame's reliance on strictly increasing timestamps, themselves rate-limited on-chain by the oracle's sixty-second minimum reading interval, for nonce uniqueness. The sealed frame is finally carried over a TLS transport and authenticated at the HTTP layer by an API key the bridge validates against the identity service, with a short-lived cache bounding that lookup.

The bridge unwinds these layers in reverse, and each is an independent gate that can drop the reading. The API key is checked first; the envelope is then decrypted, and under the hardened profile a frame that is not encrypted is refused outright with `426 Upgrade Required`, so there is no silent plaintext downgrade. Only after decryption does the bridge reconstruct the canonical string from the decoded fields and verify the Ed25519 signature against the device's registered public key, failing closed: an unverifiable reading is rejected rather than admitted unattributed. A verified reading is decoded from OBIS into the internal reading model, its owner resolved from the meter registry — a three-tier cache over Redis backed by the durable Postgres roster — and only then disseminated along the fan-out of @fig:telemetry-dissemination: the zone-partitioned Redis stream that feeds the operational path, an independent time-series store for history, the message bus, and the fifteen-minute settlement bin from which a net-surplus window later mints (@sec:cu-profile). The signing key and the encryption key are held per device and looked up separately; both lookups are cached to bound load on the identity and cache services, but the signature is verified on every reading — only the static key material is cached, never the verification verdict.

=== The Signed Mint Envelope <sec:mint-envelope>
The authorization for a surplus generation-mint is not embedded in the on-chain transaction as settlement's is; it is lifted out into the envelope the Aggregator Bridge sends to the Chain Bridge over NATS on the `chain.tx.mint` subject. The design intent is to separate provenance from transaction construction: the Chain Bridge assembles and signs the `mint_generation` transaction with its `platform_admin` key only once the envelope has passed an application-level identity check, so envelope signing is an authorization layer that runs *ahead of* the blockchain rather than a payload the on-chain program inspects.

Signing is performed over a canonical encoding designed to be unambiguous and replay-resistant. The scheme begins with the domain tag `gridtokenx-nats-envelope-v1` terminated by a zero byte, followed by a message-kind tag (`mint`) that domain-separates each kind — a signed cancel cannot replay as a submit. Each field is then encoded as its name, a zero byte, a `u64` little-endian length, and the raw value bytes. The per-field length prefix prevents shifting byte boundaries across fields to replay a captured signature, the field order is fixed (not JSON order), and the `auth` field carrying the signature is always excluded from the signed bytes because a signature cannot cover itself. The full field layout of the `mint` envelope is given in @tbl:mint-envelope-bytes. The encoding functions destructure every field exhaustively on purpose: adding a schema field without declaring it either signed or explicitly excluded is a compile error, which prevents a field that travels on the wire from silently escaping the signature.

#figure(
  caption: [Canonical signed-byte layout of the `mint` envelope on the NATS `chain.tx.mint` subject (message kind `mint`). Each row is one field encoded as `name + 0x00 + u64-LE length + value`, emitted in signing order; the buffer is prefixed with the header `gridtokenx-nats-envelope-v1\\0mint\\0`, and the `auth` field is excluded from the signed bytes.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6.5pt)
    #table(
      columns: (auto, auto, 1fr),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, left + horizon, left + horizon),
      table.header([Field], [Value encoding], [Meaning]),
      [`correlation_id`], [UTF-8], [Per-attempt UUID; routes the reply subject],
      [`idempotency_key`], [UTF-8], [`mint:{serial}:{window}`, effect-level dedup key],
      [`reply_subject`], [UTF-8], [NATS subject the sender awaits the result on],
      [`recipient_wallet`], [UTF-8], [Recipient wallet (base58)],
      [`service_identity`], [UTF-8], [SPIFFE URI of the requesting service],
      [`created_at_ms`], [`u64` LE (8B)], [Publish time (epoch ms)],
      [`energy_kwh`], [`f64` LE (8B)], [Energy amount (kWh)],
      [`meter_id`], [16 raw bytes], [Meter identifier (UUID)],
      [`window_start_ms`], [`i64` LE (8B)], [15-minute window start (epoch ms)],
    )
  ],
) <tbl:mint-envelope-bytes>

The canonical bytes above are only the *input to the signature*. What actually travels on the NATS wire is the JSON envelope (`MintEnergyMessage`) carrying those fields plus an appended `auth` object (`EnvelopeAuth`): a scheme tag `ecdsa-p256-sha256-v1`, the publisher's leaf mTLS certificate (PEM), and an ECDSA P-256/SHA-256 signature encoded ASN.1-DER then base64. The signer is the aggregator, holding the same mTLS client key that anchors the gRPC trust boundary; when no certificate/key pair is present (insecure dev mode) the envelope ships unsigned and is accepted only while the Chain Bridge runs signature verification in log-only mode. The Chain Bridge verifies in three ordered steps before building any transaction: (1) the envelope certificate chains to a trusted CA; (2) the certificate's SPIFFE SAN equals the envelope's self-asserted `service_identity` field, binding the claimed identity to a CA-issued certificate; and (3) the P-256 signature verifies against canonical bytes *recomputed* from the received fields, so tampering with any field in transit — the recipient wallet or the energy amount, say — makes the recomputed bytes differ and the signature fail. Enforcement is gated by `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS`, defaulting to log-only for gradual rollout. The engineering point is that signer and verifier share one canonical-bytes implementation from a common crate (`gridtokenx-blockchain-types`) rather than two hand-copied byte layouts, guarded by golden-vector tests that independently reconstruct the expected bytes to catch cross-crate schema drift.

Delivery of the envelope is engineered to be loss-free even when the blockchain or validator is transiently down. The envelope is published to JetStream and awaits its PubAck (durable stream storage) before awaiting a reply, closing the window where a consumer might be momentarily absent. A surplus settled out of a window but not yet landable on-chain is additionally *enqueued* into a durable outbox on Redis (`gridtokenx:billing:mint_outbox`, field `{serial}:{window}`), and a drain loop retries each entry until the mint confirms on-chain, only then removing it. The outbox survives a restart (reloaded from Redis), and the recipient wallet is re-resolved on every attempt, so a meter that registers its wallet *after* its window still mints on a later retry. Retries are safe because the Chain Bridge deduplicates on `mint:{serial}:{window_start_ms}` and the on-chain `(meter, window)` PDA is the final backstop — a retry of a mint that already landed but whose reply was lost does not double-mint. An entry that stays unlandable past `MINT_OUTBOX_MAX_AGE_SECS` (7 days by default) is *parked* out of the retry path rather than silently deleted, so an operator can re-enqueue it. The batch request on the `chain.tx.mintbatch` subject uses the same scheme but appends an item-count field and frames each item under its own length prefix, binding both the *number* and the *order* of recipients into the signature: adding, dropping, or reordering a recipient fails verification.

One field of the envelope crosses a representation boundary that is worth making explicit, because it is where an honest reading and a hostile one are separated before the token is ever minted. The energy amount travels as an IEEE-754 `f64` in kWh, but the on-chain mint operates in integer base units at nine decimals (1 kWh = $10^9$ base units, the energy token's precision). The conversion is a single shared function used by *both* the producer and the bridge verifier — the same single-source discipline as the canonical-bytes scheme — so the two never disagree on the bound or the scaling. It rejects any value that must never reach `mint_to`: non-finite (`NaN`/`±∞`), non-positive, above a hard cap `MAX_MINT_KWH` of $10^6$ kWh (1 GWh, far above any honest 15-minute window yet far below overflow), and any positive value that truncates to zero base units. The cap is load-bearing rather than cosmetic: a Rust float-to-integer cast *saturates* to `u64::MAX` for a huge input rather than wrapping, so without the bound a single envelope could request an astronomically large mint; the cap keeps the scaled value near $10^{15}$, comfortably inside `u64`. The on-chain program then re-checks the floor as defense in depth — a zero amount is rejected (`ZeroAmount`, error `6011`) before any state write, since `mint_to(_, 0)` is a silent no-op that would still stamp the window's record `minted = true` and permanently poison it — alongside the 15-minute window-boundary check in milliseconds (`MisalignedWindow`, error `6010`) and the requirement that the REC-validator co-signer differ from the platform authority (`RecValidatorIsAuthority`, error `6012`). The exactly-once record account is checked *first*, so a replay short-circuits to a no-op before any of these guards even run.

=== Signed Order Payload and Signature-Verification Instruction
The authorization that a settlement rests upon is a fixed-size 77-byte message, not a signature over a hash of the transaction. Its layout is given in @tbl:order-payload. Every field that could change the economics of the trade — the amount, the price, the side, the zone, and the expiry — is inside the signed region, so no intermediary can alter the terms after signing.

#figure(
  caption: [Borsh layout of the signed order payload (`OffchainOrderPayload`). The same 77-byte sequence is what the buyer and the seller sign off-chain and what the on-chain program reconstructs and compares byte-for-byte against the message embedded in the Ed25519 verification instruction.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6.5pt)
    #table(
      columns: (auto, auto, auto, 1fr),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (center + horizon, left + horizon, center + horizon, left + horizon),
      table.header([off], [field], [B], [encoding]),
      [0], [`order_id`], [16], [UUID, raw bytes],
      [16], [`user`], [32], [Pubkey (Ed25519 public key)],
      [48], [`energy_amount`], [8], [u64 LE],
      [56], [`price_per_kwh`], [8], [u64 LE],
      [64], [`side`], [1], [u8: 0 = buy, 1 = sell],
      [65], [`zone_id`], [4], [u32 LE],
      [69], [`expires_at`], [8], [i64 LE, Unix seconds],
      table.hline(),
      [], [*total*], [*77*], [fixed size, no length prefix],
    )
  ],
) <tbl:order-payload>

This message is carried to the validator inside a native Ed25519 precompile instruction whose data is a 2-byte preamble (signature count and padding), a 14-byte offsets header of seven `u16` values, the 64-byte signature, the 32-byte public key, and the message itself: $2 + 14 + 64 + 32 + 77 = 189$ bytes per signer. The offsets header is load-bearing for security, not merely for parsing: the program reads the public key and the message from the offsets *declared in that header*, and rejects any header whose fields point at a different instruction. Reading from fixed offsets instead would permit an attacker to construct a blob in which the native verifier validates the attacker's own key while the program reads a victim's key planted elsewhere in the same data — a settlement the victim never authorized. Verifying at the declared offsets forces the program and the native verifier to agree on the same triple.

=== Settlement Transaction Byte Budget
@tbl:packet-budget accumulates these figures into the packet budget for the batch settlement instruction. Per matched pair the transaction must carry two verification instructions (378 bytes) plus the pair's own serialized `BatchMatchPair` — the two 77-byte payloads again, together with the match amount, match price, and a 16-byte trade identifier that keys the per-match replay guard, for 186 bytes. The signed payload is therefore transmitted *twice* per signer: once inside the precompile instruction, where the native verifier needs it, and once inside the program instruction, where the program needs it to reconstruct the message. That duplication, not the account list, is what consumes the packet.

#figure(
  caption: [Instruction-data budget of `batch_settle_offchain_match` against the 1,232-byte packet limit. Values are derived from the serialized layouts (Borsh and the Ed25519 precompile format), excluding the transaction signature, message header, and blockhash (~100 bytes) and the ALT-compressed account indices (1 byte per account). Two pairs overrun the packet before those fixed costs are even added.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6.5pt)
    #table(
      columns: (1fr, auto, auto),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (left + horizon, center + horizon, center + horizon),
      table.header([component], [1 pair], [2 pairs]),
      [Ed25519 verify ix (189 B × 2 per pair)], [378], [756],
      [`BatchMatchPair` (186 B per pair)], [186], [372],
      [program ix fixed part#footnote[8-byte discriminator, 4-byte vector length prefix, 32-byte merkle root, 8-byte VAT amount, 2-byte VAT rate, 8-byte batch identifier, and a 1-byte settlement shard identifier.]], [63], [63],
      table.hline(),
      [*instruction data total*], [*627*], [*1,191*],
      [remaining of 1,232 B packet], [605], [41],
      [fixed tx overhead (sig + header + blockhash)], [~100], [~100],
      table.hline(),
      [*fits in one transaction*], [*yes*], [*no*],
    )
  ],
) <tbl:packet-budget>

The result is a hard structural cap of one matched pair per settlement transaction, even though the instruction accepts a vector of matches and the 1,400,000-CU per-transaction ceiling would admit roughly fourteen pairs at the measured 96,707 CU per pair (@sec:settlement-cost). The gap between what compute permits and what the packet permits is therefore about a factor of fourteen, and it cannot be closed with an address lookup table: the ALT replaces 32-byte account keys with 1-byte indices, and the accounts a pair adds — seven per pair, plus three or four trailing accounts for the whole batch — cost only seven bytes more per pair under compression. The binding constraint is instruction *data*, which no lookup table compresses. Closing the gap requires removing the duplicated signature material, for instance by pre-verifying signatures into accounts that the settlement then references, or by aggregating both parties' authorizations into a single off-chain multisignature. This is the concrete form of the observation in @sec:onchain-throughput that settlement throughput is a property of the transaction format.

The same budget shapes the telemetry path in the opposite direction. A single `submit_meter_reading` instruction carries at most 76 bytes of data (an 8-byte discriminator, a length-prefixed meter identifier of at most 32 bytes, two 8-byte energy counters, an 8-byte timestamp, and a 4-byte zone identifier), and its four accounts are identical across every reading of the same meter. Readings therefore batch: the month-long replay used in @sec:onchain-throughput packs ten readings per transaction by default and asserts the serialized size against the 1,232-byte limit before sending. Where settlement is packet-bound at one unit of work per transaction, metering is packet-bound at roughly an order of magnitude more — a direct consequence of one path carrying signatures inline and the other not.

The surplus generation-mint path sits at yet a third point on this spectrum. When a settlement window closes with net generation, the Aggregator Bridge mints the surplus through the energy-token program's `mint_generation` instruction, whose data is a fixed 40 bytes — an 8-byte discriminator, the 16-byte meter identifier, an 8-byte window-start timestamp in milliseconds, and an 8-byte amount — and which carries no inline signature material at all. Provenance is instead established by a mandatory registered-REC-validator co-signer at the transaction's signature level, so unlike settlement the mint neither embeds an Ed25519 payload nor pays for one in bytes. The transaction the Chain Bridge submits comprises three top-level instructions — a compute-budget instruction, an idempotent associated-token-account creation, and `mint_generation` — and occupies roughly 700–750 bytes on the wire (two 64-byte signatures, an ~80-byte header and blockhash, about thirteen 32-byte account keys, and about 50 bytes of instruction data), comfortably inside the 1,232-byte packet. A single-recipient generation mint is therefore bound by neither packet nor compute (@sec:cu-profile); its scaling behaviour is the inverse of settlement's, since many recipients batch into one transaction (`build_generation_mint_instructions`) and approach the packet wall only as the recipient count grows, rather than being capped at one unit of work. The authorization a mint rests upon travels not in the transaction but in the NATS request that precedes it: the aggregator signs a domain-tagged, length-prefixed canonical serialization of the request — the correlation and idempotency keys, the recipient wallet, the meter identifier, the window, and the energy amount — under a P-256 key whose certificate the Chain Bridge binds to the requester's SPIFFE service identity, rejecting a spoofed identity before any transaction is built. Exactly-once minting is then enforced on-chain by a per-`(meter, window)` record account whose `minted` flag short-circuits any replay to a no-op, so a settlement retried after a crash cannot double-mint.

=== The Zero-copy Account Frame
The hot-path accounts — the ones a settlement reads or writes on every transaction — use the zero-copy framing, and the `Order` account in @tbl:order-account is the representative case. Its six-byte `_padding` field is the point of interest: the two single-byte enumerations at offsets 96 and 97 leave the cursor at 98, and without the pad the following `i64` would begin at an offset that is not a multiple of eight. The pad advances the cursor to offset 104, so `created_at` and `expires_at` both land on 8-byte boundaries, which is what makes the account castable in place rather than deserializable. The consequence for maintenance is that the padding must be recomputed by hand whenever a field is added — an obligation that Borsh accounts, being packed, do not carry.

#figure(
  caption: [Zero-copy (`#[repr(C)]`) layout of the `Order` account. Offsets are fixed by C alignment rules, so the account is cast in place on every access rather than deserialized. The 6-byte pad is load-bearing: it realigns the two trailing `i64` fields to 8-byte boundaries.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6.5pt)
    #table(
      columns: (auto, 1fr, auto),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (center + horizon, left + horizon, center + horizon),
      table.header([off], [field], [B]),
      [0], [`seller` · Pubkey], [32],
      [32], [`buyer` · Pubkey], [32],
      [64], [`order_id` · u64], [8],
      [72], [`amount` · u64], [8],
      [80], [`filled_amount` · u64], [8],
      [88], [`price_per_kwh` · u64], [8],
      [96], [`order_type` · u8], [1],
      [97], [`status` · u8], [1],
      [98], [`_padding` · \[u8; 6\]], [6],
      [104], [`created_at` · i64], [8],
      [112], [`expires_at` · i64], [8],
      table.hline(),
      [], [*body* (+ 8-byte discriminator)], [*120*],
    )
  ],
) <tbl:order-account>

=== On-chain State Footprint
The last binary dimension is what each settlement leaves behind on-chain, summarized in @tbl:account-sizes. The design intent visible in these sizes is that per-entity accounts stay small enough for rent to be negligible and for the write set of unrelated transactions to remain disjoint, which is what allows Sealevel to schedule them in parallel (@sec:smart-contract-programs).

#figure(
  caption: [On-chain footprint of the accounts written on the settlement and metering paths, including the 8-byte Anchor discriminator. Per-entity accounts are deliberately small; only the singleton governance account is oversized, by design, to reserve room for upgrades.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6.5pt)
    #table(
      columns: (auto, auto, 1fr),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (left + horizon, center + horizon, left + horizon),
      table.header([account], [B], [encoding · composition]),
      [`TradeNullifier`], [9], [Borsh; 8 + bump — existence _is_ the guard],
      [`OrderNullifier`], [65], [Borsh; 8 + 16 + 32 + 8 + 1 (cumulative fill)],
      [`MeterState`], [102], [Borsh; 8 + 32 + 1 + 1 + 4 + 7 × 8],
      [`SettlementRecord`], [120], [zero-copy; 8 + 112 (root, VAT, id, pad)],
      [`Order`], [128], [zero-copy; 8 + 120 (see @tbl:order-account)],
      [`GovernanceConfig`], [413], [Borsh; 8 + 405, reserved space],
    )
  ],
) <tbl:account-sizes>

Two entries deserve comment. Both zero-copy accounts (`Order`, `SettlementRecord`) carry explicit padding to a multiple of eight for the reason given above, whereas the Borsh accounts do not. The per-match `TradeNullifier` is nine bytes — a discriminator and a bump seed — because it stores no state at all: its mere existence, created atomically with the settlement it guards, is what makes a replayed match fail. It is the cheapest possible encoding of a replay guard, and it is distinct from the `OrderNullifier`, which must store a cumulative filled amount because orders settle partially (@sec:settlement-model). At the other extreme, `GovernanceConfig` is pinned at a constant 405 bytes of payload with explicit reserved space, precisely because other programs deserialize it themselves — they skip the 8-byte discriminator and decode the fields by position — so its layout is a compatibility surface. Fixing the size and reserving the tail means new governance fields can be added without migrating an account that every order-creation instruction in the system reads.

=== Which Ceiling Binds: Six Runtime Limits <sec:ceilings>
The byte budgets of the preceding subsections are not isolated facts; they are three of the six hard runtime ceilings a Solana-compatible program must fit inside simultaneously, and the design of this system is legible only when all six are seen at once. @tbl:ceilings lists them together with the escape each one forces. The compute-unit budget of @sec:settlement-cost is the ceiling most often assumed to bind, but in this workload it almost never does: the transaction packet size and the validation stack bite first.

#figure(
  caption: [The six runtime ceilings a settlement transaction must satisfy at once, and the mechanism this system uses to stay under each. Compute units — the ceiling usually assumed to bind — is here the slackest of the three that matter; packet size and validation-stack size are the ones that actually constrain the design.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6pt)
    #table(
      columns: (auto, auto, 1fr),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (left + horizon, left + horizon, left + horizon),
      table.header([ceiling], [limit], [escape used here]),
      [CU budget], [200k / 1.4M per ix], [zero-copy cast; one-CPI batch],
      [tx size], [1,232 B (packet)], [ALT — but cannot compress Ed25519 data],
      [BPF stack], [4 KB per frame], [`remaining_accounts` slice, not typed field],
      [heap], [32 KB bump, no free], [avoid heap growth; `Box` only to offload stack],
      [CPI depth], [4], [acyclic graph, longest chain 3 hops],
      [account data], [10 MB; 10 KB realloc/ix], [sharded per-entity PDAs],
    )
  ],
) <tbl:ceilings>

A compute unit is a meter of execution work — bytecode instructions, syscalls such as clock reads, SHA-256, and Ed25519 verification, cross-program invocations, and account (de)serialization — and it is distinct from the fee, which is charged separately per signature and per priority bid. The property that makes it easy to over-attribute cost to compute is that a CPI adds the *callee's* consumption to the *same* meter: invocation depth and context fatness compound on one budget. Even so, every instruction in this system's real execution path is measured to sit well under the 200,000-CU default — the hot writes at a few thousand CU each (@fig:cu-profile), the signature-verifying settlement near half the budget (@sec:settlement-cost) — and the LiteSVM profile tests assert each instruction stays under that default, so a handler that suddenly needs a raised budget is treated as a regression rather than accommodated. The default budget is, in effect, a health bar.

The first ceiling that actually binds is the packet size, and its analysis is exactly the batch-settlement argument of @sec:wire-formats: because each match carries a 77-byte signed payload and a 64-byte signature inside instruction *data*, which no address lookup table can compress, the packet fills at one match per transaction long before the 1.4-million-CU ceiling — which would admit roughly fourteen — is approached. Compute is cheap here; the packet is the wall.

The second binding ceiling is subtler because it strikes before the handler even runs. Anchor materializes every account of a `#[derive(Accounts)]` context onto the current 4-KB stack frame during `try_accounts`, so a context with too many typed fields overflows validation with a build-time *stack offset exceeded* error, independent of anything the handler does. The settlement context sits at this ceiling: one more typed account field would overflow it. This is the direct cause of a design choice visible throughout the settlement code — the governance config, the tariff config, the optional zone-capacity account, and the treasury accounts all travel through `remaining_accounts`, a bare slice that costs no stack, and are validated in the handler body by owner check and PDA re-derivation on their raw bytes. That is why the read gates of @sec:cpi are raw-byte reads rather than typed Anchor accounts: it is not merely an optimization but the only way the context fits under 4 KB. The cost paid is Anchor's automatic typed validation, and it is paid back explicitly with the manual owner-and-PDA re-derivation described earlier.

The remaining three ceilings shape the system more quietly. The 32-KB bump-allocated heap, which is never freed within an instruction, is the reason handlers avoid growing large vectors and use `Box` only to move an account off the stack rather than to allocate freely. The CPI depth limit of four is the reason the composition graph of @sec:cpi is kept acyclic and shallow, its longest chain three hops. And the 10-MB account-size limit, with its 10-KB per-instruction growth cap, is one of the reasons state is sharded into per-entity accounts rather than accumulated into a few large ones — the same sharding that @sec:write-set relies on for parallelism. The shape of the whole system is thus not a response to any single ceiling but the intersection of all six: zero-copy layout answers compute and stack together, per-entity sharding answers account size and parallelism together, the one-CPI batch answers packet size and depth and compute at once, and `remaining_accounts` answers the stack at the price of hand-written validation.

== Composition of Programs: Cross-Program Invocation <sec:cpi>
The six on-chain programs are not independent contracts that happen to share a network; they compose. A settlement in the trading program reaches into the treasury to reconcile the cash figure, a registry mint reaches into the energy-token program to issue supply, and a governance certificate reaches into the registry to mark the underlying energy as spent. This composition is expressed through Cross-Program Invocation (CPI), the mechanism by which one program calls another within a single transaction, and its structure is what makes the invariants of @sec:settlement-model hold *across* program boundaries rather than only within one.

What matters architecturally is that the system uses two different mechanisms for two different kinds of dependency, and does not confuse them. A *state-changing* dependency — one program must cause a write in another — is a CPI, and the caller must sign it. A *policy-reading* dependency — one program must consult another's state to decide whether to proceed — is deliberately *not* a CPI: the reading program validates the account's owner and its Program Derived Address, then deserializes the bytes itself. The second form avoids the compute cost and the account-passing overhead of an invocation, and reduces policy enforcement to checking the accounts already submitted with the transaction. @tbl:cpi-edges enumerates both kinds across all six programs, and @fig:cpi-graph shows the resulting call graph.

#figure(
  caption: [Program composition across the six on-chain programs. Solid edges are Cross-Program Invocations (a state change in the callee, authorized by the caller's signing authority); dashed edges are read-only policy gates that validate owner and PDA and deserialize in place *without* an invocation. Every CPI signer is a Program Derived Address except the governance-to-registry edge, which carries the human authority's signature.],
  text(size: 7pt)[
    #diagram(
      spacing: (11mm, 8mm),
      node-stroke: 0.6pt,
      {
        let prog = rgb("#eef3fb")
        let ext = rgb("#e8f5ec")
        let blue = rgb("#3c6fa0")
        let green = rgb("#3f7d52")
        let gray = rgb("#888888")
        node((0, 0), align(center)[*governance*], shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + blue, fill: prog)
        node((1, 0), align(center)[*registry*], shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + blue, fill: prog)
        node((2, 0), align(center)[*energy-token*], shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + blue, fill: prog)
        node((0, 1), align(center)[*oracle*], shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + blue, fill: prog)
        node((1, 1), align(center)[*trading*], shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + blue, fill: prog)
        node((2, 1), align(center)[*treasury*], shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + blue, fill: prog)
        node((2, 2), align(center)[Token-2022 \ (SPL interface)], shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + green, fill: ext)
        edge((0, 0), (1, 0), "-|>", stroke: 0.6pt + blue, label: text(5pt, fill: blue)[mark_erc_claimed])
        edge((1, 0), (2, 0), "-|>", stroke: 0.6pt + blue, label: text(5pt, fill: blue)[mint_tokens_direct])
        edge((1, 1), (2, 1), "-|>", stroke: 0.6pt + blue, label: text(5pt, fill: blue)[record_settlement])
        edge((2, 0), (2, 2), "-|>", stroke: 0.6pt + green, label: text(5pt, fill: green)[mint_to])
        edge((1, 1), (2, 2), "-|>", stroke: 0.6pt + green, label: text(5pt, fill: green)[transfer_checked])
        edge((2, 1), (2, 2), "-|>", stroke: 0.6pt + green)
        edge((1, 1), (0, 0), "--|>", stroke: (paint: gray, dash: "dashed", thickness: 0.5pt), label: text(5pt, fill: gray)[read gate])
        edge((0, 1), (0, 0), "--|>", stroke: (paint: gray, dash: "dashed", thickness: 0.5pt), label: text(5pt, fill: gray)[read gate])
      },
    )
  ],
) <fig:cpi-graph>

#figure(
  caption: [Composition edges among the on-chain programs. The upper block lists Cross-Program Invocations with the authority that signs each one; the lower block lists read-only policy gates, which perform no invocation. SPL token transfers, mints, and burns are ordinary CPIs into the token programs and are shown once per calling program.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6pt)
    #table(
      columns: (auto, 1fr, auto),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (left + horizon, left + horizon, left + horizon),
      table.header([caller → callee], [instruction], [signer]),
      table.cell(colspan: 3)[_Cross-Program Invocation (state-changing)_],
      [trading → treasury], [`record_settlement`], [`market_authority`],
      [trading → treasury], [`record_settlement_batch_sharded`], [`market_authority`],
      [registry → energy-token], [`mint_tokens_direct` (settle-and-mint)], [`registry`],
      [registry → energy-token], [`mint_tokens_direct` (airdrop claim)], [`registry`],
      [governance → registry], [`mark_erc_claimed`], [authority],
      [energy-token → token], [`mint_to`], [`token_info_2022`],
      [trading → token], [`transfer_checked` (DvP legs)], [`market_authority`],
      [governance → token], [`mint_to` (REC issuance)], [`governance_config`],
      [treasury → token], [`transfer_checked` — stake deposit], [user],
      [treasury → token], [`transfer_checked` — unstake, rewards], [`treasury`],
      [registry → token], [`transfer_checked` — stake deposit], [user],
      [registry → token], [`transfer_checked` — unstake, slash], [`registry`],
      table.cell(colspan: 3)[_Read-only policy gate (no invocation)_],
      [trading → governance], [`GovernanceConfig` — maintenance mode], [—],
      [trading → governance], [`AggregatorEntry` — operator admitted], [—],
      [oracle → governance], [`AggregatorEntry` — operator admitted], [—],
      [registry → oracle], [meter totals bound registry totals], [—],
    )
  ],
) <tbl:cpi-edges>

Two properties of this structure carry the correctness argument. First, the direction of authority follows the direction of value. Every CPI that moves value *out of* a program-controlled account is signed by a Program Derived Address rather than by a user key: the settlement's transfers out of escrow and its treasury reconciliation are both signed by the `market_authority` PDA, the registry's mints by the `registry` PDA, the energy-token program's underlying token mint by its own `token_info` PDA, and staking payouts by the `treasury` and `registry` PDAs respectively. Transfers *into* a program-controlled account — a stake deposit, an escrow funding — are signed by the depositing user instead, which is the correct assignment: a program should need no authority to receive, and a user should retain sole authority to part with their own balance. Because a PDA has no private key and can only be signed for by the program that owns its seeds, authority to disburse is a property of the *code path*, not of a key an operator holds. Authorization of the settlement itself still comes from the buyer's and seller's Ed25519 signatures (@sec:wire-formats); the PDA signature only executes what those signatures already authorized. The one administrative edge is governance-to-registry, where the certificate issuer's own signature is carried through, which is appropriate because issuing a Renewable Energy Certificate is a deliberate act rather than an automated one.

Second, the composition is shallow and acyclic. The three internal edges form a directed acyclic graph — governance points at registry, registry at energy-token, trading at treasury — with no back edges, so no program can be re-entered through a chain it began, which removes an entire class of reentrancy hazard by construction rather than by guard. The deepest chain is the token-issuance path — a client instruction into the registry, which invokes the energy-token program, which in turn invokes the Token-2022 program — giving an invocation depth of three against the platform's limit of four. The settlement path is shallower still: `settle_offchain_match` invokes the token program for the delivery-versus-payment legs and the treasury for reconciliation, both at depth two. Shallow composition matters here for the same reason thin instructions do: each nested invocation carries its own account-passing and compute overhead inside the caller's budget, so a deep chain would consume the compute headroom that @sec:settlement-cost reports as available. Keeping every value-moving path at depth two or three is what allows the measured settlement cost to remain near 48% of the per-instruction budget even though a settlement spans three programs. Every internal invocation follows the Anchor 1.0 idiom in which the `CpiContext` is constructed from the callee program's public key rather than its account handle — a breaking change from the 0.30 series that the codebase has adopted uniformly.

The callee's admission rules deserve their own note, because a CPI edge is only as safe as the gate on the receiving side. Two of the three internal edges carry a deliberate exemption for their sole legitimate caller. The energy-token program normally requires that a mint be co-signed by a registered Renewable Energy Certificate validator; the registry's mint path is exempt from that membership check, because those are protocol mints — an airdrop claim or a settled-generation mint — guarded by their own on-chain conditions rather than by a validator co-signature, and the registry passes its own PDA where a validator key would otherwise go, a placeholder that can never appear in the validator set. This is the one path allowed to create supply without an external co-signer, so its gate is instead that the caller *is* the registry PDA. Symmetrically, on the receiving side of the governance edge, `mark_erc_claimed` accepts only the registry authority as signer, and since `issue_erc` already forces its own signer to equal that authority, the CPI is the sole path that can satisfy the gate.#footnote[Two further hardenings of these gates — pinning the callee to `energy_token::ID` on the registry side, and narrowing `mark_erc_claimed` to the registry authority alone (previously it also accepted the oracle authority) — exist in the working tree but are not part of the commit evaluated in this paper; they are reported here as the intended end state, not as measured behavior.]

Finally, this is where the conservation invariant of the energy tokens becomes enforceable across programs rather than within one. The registry may only mint energy that the oracle has accepted, because the registry's totals are bounded by the meter totals it reads; governance may only certify surplus that the registry has not already tokenized, because `issue_erc` invokes `mark_erc_claimed` in the same transaction as the certificate it creates; and the trading program may only settle tokens that exist, because the transfer legs are real token movements rather than ledger entries. The chain metered ≥ minted ≥ settled ≥ burned, with the withheld remainder certified as RECs, therefore holds not by convention between services but because each link is a CPI that fails atomically with its caller.

== Token Model, Mint and Burn Authority, and the THBC Peg <sec:token-model>
The composition described above moves three distinct token types, and the correctness of the whole economy rests on each having a mint authority that no operator can forge and a burn that is a genuine supply reduction. @tbl:token-model lists the three. Two points are easy to get wrong and worth stating plainly: the energy token appears under two names — GRID in its energy role and GRX in its collateral and staking role — but it is a *single* mint, not two, and the units of the three tokens differ by orders of magnitude, so every cross-token computation carries an explicit scale factor.

#figure(
  caption: [The three token types, their owning program, and their units. GRID and GRX are one mint under two role-names, not two mints. All three are Token-2022 mints; each mint authority is a Program Derived Address of its owning program, so no operator key can mint directly.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6pt)
    #table(
      columns: (auto, auto, auto, 1fr),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (left + horizon, left + horizon, center + horizon, left + horizon),
      table.header([token], [mint owner], [dec], [unit · role]),
      [GRID / GRX], [energy-token], [9], [1 kWh = 1 GRID (kWh × $10^9$); energy, and collateral as GRX],
      [REC], [governance], [6], [1 token = 1 MWh (kWh × 1000); renewable certificate],
      [THBC], [treasury], [6], [1 THB = $10^6$ minor; settlement currency, THB-pegged],
    )
  ],
) <tbl:token-model>

Each mint is gated by a condition that ties new supply to something real. GRID is minted only through the energy-token program's three paths, every one of which requires the mint to be co-signed by a registered Renewable Energy Certificate validator — with the single registry exception noted in @sec:cpi — and a zero-amount mint is rejected rather than allowed to emit a phantom event against no supply. REC is minted by governance at 1,000 base units per kWh, bounded by net unclaimed generation and coupled to the `mark_erc_claimed` write, so certified renewable supply can never exceed the metered generation that backs it. THBC, the settlement currency, is minted only by the treasury's swap instruction under the peg guards below. Burns are symmetric and each is a real reduction: GRID is burned on consumption or compliance retirement, REC is burned to retire a certificate, and THBC is burned on redemption back to GRX.

The THBC peg is the part that most resembles a conventional stablecoin, and its safety reduces to four inequalities across two instructions. Minting THBC by swapping in GRX computes

$ "gross" &= floor("grx"_"in" dot rho slash 10^9) #<eq:swap-gross> \
  "fee" &= floor("gross" dot phi_s slash 10^4) #<eq:swap-fee> \
  "net" &= "gross" - "fee" #<eq:swap-net> $

where $rho$ is the configured GRX-per-THBC rate and $phi_s$ the swap fee in basis points, and the mint proceeds only if two guards hold: the reserve attestation must be fresh — the current time minus the attestation timestamp within the configured time-to-live — and the resulting supply must not breach the reserve ceiling,

$ "thbc_supply" + "net" &<= "attested_reserve". #<eq:peg-ceiling> $

A single minor unit over the attested reserve rejects the whole swap. Redemption runs the inverse, $"grx"_"out" = floor("thbc"_"in" dot 10^9 slash rho)$, under two collateral guards: the burned amount may not exceed the tracked THBC supply, and the GRX paid out may not exceed what the swap vault actually holds. Together these mean that even a mis-set rate cannot let a redeemer drain more GRX than the vault contains, and cannot let outstanding THBC exceed the attested reserve — the peg holds by arithmetic at each instruction, not by an external market maker. Every product in these computations is evaluated in 128-bit arithmetic and checked on truncation back to 64 bits, so an overflow is a rejection rather than a wrap. The reserve attestation itself is refreshed by a custodian through a dedicated instruction, which is the one trusted input the peg depends on and the natural audit point.

One structural separation makes the peg robust against the system's own staking. GRX is held in four *distinct* vault accounts — swap-redemption collateral, staker custody, staker rewards, and a regulator or slash pool — each its own Program Derived Address. Staked GRX therefore lives outside the collateral that backs THBC and is never counted in the attested reserve, so a staking withdrawal cannot weaken the peg and a redemption cannot touch stakers' bonds. This also keeps the two staking systems apart: the treasury's yield staking and the registry's validator-bond staking (@sec:treasury-program) draw on separate vaults, and neither one's staked balance backs the settlement currency. The result is that the token economy composes into a single closed loop — generation mints GRID under a validator co-sign, governance certifies the unclaimed remainder as REC, a producer may swap GRID-as-GRX into THBC under the peg guards, trades settle in THBC through the charge waterfall of @sec:settle-pipeline with the gross value recorded in the treasury, consumers burn GRID for compliance and retire RECs, and holders redeem THBC back to GRX under the vault guards — in which every mint is gated to something real, every burn genuinely reduces supply, and the settlement currency cannot be printed beyond its reserve.

== Renewable Energy Certificates: The Dual Representation <sec:rec-model>
The Renewable Energy Certificate deserves its own treatment because it is the one instrument in the system that deliberately exists in *two* forms at once, and both are created in a single issuance. The reason is that a certificate must serve two incompatible purposes: it is a legal and audit object, which wants a unique, individually addressable record carrying a full lifecycle, and it is simultaneously a market instrument, which wants a fungible balance that can be split, traded, and retired by quantity. Rather than choose, the governance program mints both — an `ErcCertificate` account and a quantity of fungible REC tokens — atomically in the `issue_erc` instruction, so the record and the tradeable balance can never disagree about how much renewable energy was certified. @tbl:rec-dual contrasts the two forms.

#figure(
  caption: [The two representations of a Renewable Energy Certificate, both created in one `issue_erc` call. The account is the legal/audit record; the fungible token is the market instrument. Their quantities are locked together by construction — one kWh of certified energy is one kWh on the record and 1,000 base units of the token.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6pt)
    #table(
      columns: (auto, 1fr, 1fr),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (left + horizon, left + horizon, left + horizon),
      table.header([], [`ErcCertificate` PDA], [fungible REC token]),
      [owner], [governance program (Borsh `#[account]`)], [Token-2022 mint `[rec_mint]`],
      [nature], [one record per certificate, full lifecycle], [fungible balance, 6-decimal],
      [unit], [`energy_amount` in kWh], [1 token = 1 MWh (1 kWh = 1,000 units)],
      [managed by], [issue / validate / revoke / transfer], [mint on issue, burn on retire, trade],
      [purpose], [audit trail: status, expiry, revocation], [tradeable / retireable instrument],
    )
  ],
) <tbl:rec-dual>

The certificate record is intentionally verbose where the token is intentionally minimal. It carries the certificate identifier, the issuing authority and the current owner, the certified energy amount in kWh, the renewable source, free-form validation data, issuance and optional expiry timestamps, a status, a separate trading-eligibility flag with its own timestamp, and explicit revocation and transfer tracking. Consistent with the audit-document discipline noted for the metering frame in @sec:wire-formats, every variable-length field is a fixed byte array plus a length byte rather than a `String`, so the record's size — and therefore its on-chain layout — is constant regardless of content.

The record moves through a small state machine, and the subtlety worth stating is that *validity* and *tradeability* are two independent flags, not one. Issuance sets the status to `Valid` but leaves the trading-eligibility flag false, so a freshly issued certificate is a legitimate audit object that is not yet tradeable; a separate authority action, `validate_erc_for_trading`, flips that flag and is the point at which the certificate becomes a market instrument. Transfer of the record is permitted only while it is `Valid` and validated for trading, whereas revocation is permitted while it is `Valid` or `Pending`; revocation is terminal, clears the trading flag, requires a stored reason, and cannot be applied twice. Expiry, when a certificate carries an expiry timestamp, moves it out of the tradeable set once the clock passes it. Splitting validity from tradeability this way lets the system issue a certificate the instant generation is certified while gating its entry to the market behind a distinct, separately auditable approval.

The quantity relationship between the two forms is fixed everywhere by the same factor. The fungible mint is six-decimal with one token defined as one megawatt-hour, so one kWh is exactly 1,000 base units, and that factor appears identically at the three points where the two representations meet: when `issue_erc` mints the token against the record's kWh amount, when a sell order's optional REC balance is checked against the order's kWh quantity, and when settlement transfers the REC alongside the energy. Because the same factor is used at every crossing, a certificate's recorded kWh and its fungible balance stay in lockstep by construction rather than by reconciliation.

What ultimately bounds the fungible supply is the same net-generation constraint that governs GRID. Issuance requires the certified amount to be no greater than the meter's *unclaimed* net generation, computed as generation minus consumption, minus energy already claimed as certificates, minus energy already settled — and while the governance program checks this locally to fail fast, the authoritative check is the `mark_erc_claimed` invocation into the registry (@sec:cpi), which re-verifies on the same net basis and reverts the whole transaction if exceeded. Combined GRID settlement and REC issuance therefore can never exceed a meter's net generation, so total fungible REC supply is bounded to certified-and-claimed net generation, and because retirement only ever burns, that supply is monotonically non-increasing once certificates are retired. This is the certificate-side half of the conservation chain of @sec:cpi: the green attribute is minted only against real, unclaimed generation and is destroyed when surrendered.

At the market, the two representations are checked independently and both must agree. When a sell order references a certificate, the order-time gate requires the record to be `Valid`, unexpired, validated for trading, sized to at least the order's energy, and — a check the record alone does not imply — actually owned by the order's author, so that a validated certificate belonging to someone else cannot satisfy the gate. Separately and optionally, if the seller appends a fungible REC token account, it must be an account of the real governance mint, owned by the seller, and holding at least the order's kWh times 1,000 base units. At settlement the fungible REC then moves from the seller's escrow to the buyer's in the same instruction that moves the energy, so the green attribute follows the energy it certifies rather than drifting free of it.

== Authority Catalog and Cross-Program Identities <sec:authority-catalog>
The gates named throughout this section are enforced by a small set of stored authority keys, and it is worth collecting them in one place because the security of the whole system reduces to *who* each key is and *what* it may do. @tbl:authority-catalog is that catalog, grouped by owning program. Two organizing principles run through it. First, the human-held keys are few and administrative — a single Proof-of-Authority key in governance, an admin key per program — while the keys that actually move value on the hot path are Program Derived Addresses, not keys any operator holds. Second, several of those PDAs are the *same identity wearing two hats* across a program boundary, which is precisely what lets a cross-program invocation carry authority without sharing a private key.

#figure(
  caption: [Stored authority keys by program and what each gates. Human-held keys (the governance PoA authority, per-program admins, meter/user owners) are administrative; the value-moving authorities on the hot path are Program Derived Addresses. Aggregator admission and validator bond are enforced through per-entity accounts rather than a single stored key.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6pt)
    #table(
      columns: (auto, auto, 1fr),
      inset: (x: 3.5pt, y: 2.5pt),
      align: (left + horizon, left + horizon, left + horizon),
      table.header([authority], [kind], [gates]),
      table.cell(colspan: 3)[_governance — the PoA control plane_],
      [`authority`], [PoA key], [issue/validate/revoke/transfer ERC, config, aggregator admit/revoke, oracle-authority set, authority-change propose],
      [`pending_authority`], [PoA key], [2-step transfer target; must sign `approve`; 48 h expiry],
      [`oracle_authority`], [ref key], [oracle-validation reference],
      [`AggregatorEntry` PDAs], [per-node], [admitted nodes; segment 0 = retail, 1 = wholesale; read by oracle + trading],
      table.cell(colspan: 3)[_energy-token_],
      [`authority`], [admin key], [mint-authority ref; add/remove REC validator],
      [`registry_authority`], [PDA], [the registry PDA allowed to CPI-mint, exempt from REC co-sign],
      [`rec_validators[5]`], [co-signers], [REC co-signer set; every human-driven mint needs one],
      table.cell(colspan: 3)[_registry_],
      [`authority`], [admin key], [admin ops; 2-step `update_authority`],
      [`slash_destination`], [sink key], [sink for slashed bonds; slash refuses until set],
      [`UserAccount.authority`], [owner key], [user / meter owner; validator bond + status],
      table.cell(colspan: 3)[_trading_],
      [`Market.authority`], [PDA], [`market_authority`; = treasury recorder; signs settle + record CPI],
      [`wheeling`/`loss_authority`], [ref keys], [bind tariff rates to grid-operator authority],
      [settlement payer], [admitted], [must be a governance-admitted aggregator; wholesale needs wholesale segment],
      [`OrderNullifier.authority`], [owner key], [= the order signer (replay binding)],
      table.cell(colspan: 3)[_treasury_],
      [`authority`], [admin key], [set params, pause, refresh reserve attestation],
      [thbc mint authority], [PDA], [`[treasury]` PDA mints / burns THBC],
      [`settlement_recorder`], [PDA], [only caller allowed to record settlement = trading `market_authority`],
      table.cell(colspan: 3)[_oracle_],
      [`authority`], [admin key], [oracle admin],
      [`chain_bridge`], [ref key], [the sole key authorized to submit meter readings],
    )
  ],
) <tbl:authority-catalog>

The cross-program identity aliases are the heart of why this catalog is small rather than sprawling. The trading program's `market_authority` PDA *is* the treasury's stored `settlement_recorder`, so the treasury can insist that only that one PDA records a settlement, and the trading program can satisfy that check simply by signing the reconciliation invocation as itself — no shared secret, no third key. In the same way, the registry PDA is exactly the `registry_authority` that the energy-token program exempts from the REC co-sign requirement, so "a mint the registry initiated" and "a mint allowed to skip the validator co-signature" are one and the same condition rather than two that must be kept in agreement. And the governance config PDA is the mint authority of the REC token, so issuing a certificate and minting its fungible form are authorized by a single identity. Each alias collapses what would otherwise be a trust relationship between two keys into a single PDA that only one program can sign for, which is the same property that made the disbursement argument of @sec:cpi hold.

Finally, the keys that *can* change hands change hands carefully. Every administrative authority that supports transfer does so in two steps rather than one — governance through a propose-then-approve handshake that the incoming authority must itself sign and that expires after 48 hours, and the registry and energy-token admins through their own equivalent two-step updates. The effect is that authority can never be moved to a mistyped or unreachable key, because the recipient must actively accept it within a bounded window; a fumbled handover simply expires and leaves the incumbent in place. For a permissioned network whose entire trust model rests on the identity of a small authority set, making the handover of that identity fail-safe is not a detail but a load-bearing part of the design.
