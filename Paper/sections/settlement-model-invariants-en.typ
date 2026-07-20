#import "@preview/cetz:0.5.2"

= SETTLEMENT MODEL <sec:settlement-model>

== Architecture Overview
This work partitions responsibility into two interconnected trust domains joined through a single point. The off-chain trust domain performs validation and matching: it comprises the metering layer (a Smart Meter Simulator following the AMI standard and DLMS/COSEM) that feeds data into the Aggregator Bridge to verify Ed25519 signatures and screen the data, before forwarding it to the Trading Service, which matches orders using the Continuous Double Auction (CDA) algorithm, with the IAM Service and Notification Service supporting identity and notification. The on-chain trust domain settles transactions and records evidence: it comprises a set of Anchor programs (registry, trading, oracle, energy-token, governance, and treasury) on a permissioned (consortium) Solana-compatible network that records state into PDA accounts and an event log.

The crossing from the off-chain domain to the on-chain domain occurs solely through the Chain Bridge, the only service that contacts Solana RPC directly. It receives write commands over NATS JetStream and serves state reads over ConnectRPC on a channel protected by mTLS. The on-chain programs are Anchor programs @anchorDocs running on the Solana Virtual Machine (SVM) @yakovenkoSolanaWhitepaper and use Program Derived Addresses (PDA) to create accounts whose ownership is deterministically verifiable. Separating the two domains in this way means that power-engineering validation and access control happen before a transaction is recorded, while the blockchain serves as a thin settlement and audit layer. The full details of the services, their connectivity, and the architecture diagram appear in @sec:system-architecture. This article is an architectural evaluation on a simulated system, not a measurement from a production Solana network.

== Settlement Model
The settlement model separates responsibility into two layers with clearly distinct trust boundaries. The off-chain layer performs validation and matching: it comprises the Aggregator Bridge, which verifies the Ed25519 signatures of meter readings, checks the data format against the DLMS/COSEM standard, and evaluates available-surplus conditions together with grid stability; and the Trading Service, which matches buy/sell orders using the Continuous Double Auction (CDA) algorithm. The output of this layer is a validated order pair together with an order payload signed by both parties. The on-chain layer is an Anchor program @anchorDocs that acts as a thin settlement and audit layer, accepting only validated order pairs and recording an auditable result.

Before recording a settlement, the on-chain program enforces only conditions that are verifiable from the payload and account state, namely: account-ownership checks, the Ed25519 signatures of both buyer and seller on the order payload, double-submission prevention via the order nullifier account, and the validity of the escrow state. Conditions that require external data, such as available surplus and oracle attestation, are enforced in the off-chain layer before submission and are not re-checked on-chain. This division of responsibility means the blockchain need not directly trust external data, yet can confirm that every settlement originates from an order pair genuinely signed by both parties. All account structures use Program Derived Addresses (PDA) to isolate the state of each transaction and to verify ownership deterministically. The details of the programs and PDA accounts are described in @sec:smart-contract-programs @solanaPdaDocs.

== Atomic Delivery-versus-Payment
A matched order pair is settled through the `settle_offchain_match` instruction of the trading program, which operates as delivery-versus-payment (DvP) within a single transaction; that is, the transfer of funds and the transfer of energy happen together or not at all. If any transfer fails, the entire transaction is reverted, so there is no lingering state in which one party has received while the other has not. Before the transfer, the program checks the Ed25519 signatures of both the buyer (instruction sysvar index 0) and the seller (index 1) over a message that binds the order's key fields, namely order_id, user, energy_amount, price_per_kwh, side, zone_id, and expires_at, making it impossible to alter the amount or price after signing. It then checks the price-crossing condition, namely that the match price must lie within the range $p_s <= p^* <= p_b$, checks the side of both parties, and checks the expiry time.

Settlement is partial-fill: the order nullifier account (seed `[nullifier, user, order_id]`) stores the accumulated filled amount (filled_amount) instead of a boolean value, so an order can be filled multiple times up to the signed amount, but the total will not exceed that amount ($"match" <= "energy_amount" - "filled"$) on either side. For cross-zone transactions that use inter-zone transmission lines, the program additionally enforces a cap on the accumulated committed flow on-chain ($"committed_flow" + "match" <= "capacity"$), whereas transactions within the same zone are exempt because they do not use inter-zone transmission lines. Once all conditions pass, the total value and the shares are computed as follows, with currency flowing from the buyer escrow to the fee/wheeling/loss collectors and the seller escrow, and energy (energy token) flowing from the seller escrow to the buyer escrow. All transfers out of the escrow accounts are signed by the market_authority PDA as the owner of the escrow accounts (signing the token-transfer CPI), while authorization of the settlement comes from the Ed25519 signatures of the buyer and seller as described above. Besides the single-match instruction, the program also has a batch settlement instruction (`batch_settle_offchain_match`) that can combine up to 4 pairs per transaction to reduce cost, using the very same set of validation conditions (Ed25519 signatures, order nullifier, price crossing, and the cross-zone flow cap), and binding accounts from the signed payload by checking the Program Derived Address (PDA) of every account passed in.

$ V &= "match" dot p^* #<eq:settle-value> \
  "fee" &= floor(V dot phi slash 10000) #<eq:settle-fee> \
  "net"_s &= V - "fee" - w - c_("loss") #<eq:settle-net> $

This set of equations is the on-chain rounded-down integer (fixed-point) form of @eq:value through @eq:net in @sec:pricing-model, where $V$ is the total value leaving the buyer escrow, $phi$ is the market fee (market_fee_bps), $w$ is the wheeling charge, $c_("loss")$ is the loss cost (see @eq:loss-cost), and $"net"_s$ is the seller's net amount. All computations use checked arithmetic instead of clamping values; that is, the value multiplication rejects the overflow case, and the deduction of the seller's net will *reject* the transaction (require! with error `ChargesExceedValue`) when the sum of the fee, wheeling and loss exceeds the value $V$, instead of rounding the amount down to zero, together with a cap on the total network fees of no more than 20% of $V$. When the market is configured to settle in THBC, the system enforces recording the gross value through the `record_settlement` CPI to the treasury program, so that the settlement counter reconciles against the actual cash flow leaving escrow.

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

A single settlement transaction comprises one settle instruction together with two Ed25519 signature-verification instructions per matched pair (for the buyer and the seller) that the program verifies through the instruction sysvar, where the signature payload (signature, public key and the canonical message, totaling about 189 bytes per instruction) resides in the instruction data, not in the accounts, so the address lookup table (ALT), which compresses only the account list, cannot reduce the size of this part. For this reason, even though the program permits batch settlement of up to 4 pairs per transaction (`batch_settle_offchain_match`), the practical cap is constrained by the 1,232-byte transaction packet size: combining two pairs (4 signature-verification instructions at about 760 bytes, together with the serialized BatchMatchPair at about 370 bytes, plus the account index list and header) already exceeds the packet size. Increasing the actual number of pairs per transaction therefore requires changing how the signatures are packed (for example, pre-verified signature accounts, or an off-chain aggregated multisig), not merely increasing the number of pairs. The accounts the transaction touches comprise the buyer's and seller's escrow accounts, the order nullifier accounts of both sides, the zone_market account, and the fee/wheeling/loss collector accounts in the treasury. This structural constraint explains why the batching cap and the throughput of settlement are tied to the transaction format, which is consistent with the measurement results in @sec:onchain-throughput.
