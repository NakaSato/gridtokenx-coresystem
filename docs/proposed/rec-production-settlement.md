# Proposal — Enabling REC Settlement Transfer in Production

> **Status: OPEN DECISION.** Decision-support, not a decision. Prepared 2026-07-01.
> Companion: `gridtokenx-anchor/docs/design/rec-certificates.md` (§5 + production-wiring status).

## Context

The fungible REC token (1 token = 1 MWh) is built end-to-end on chain: minting on
`issue_erc`, the order-time balance gate, and a **settle-transfer** that moves the matched
REC *seller → buyer* on settlement. Both on-chain settle handlers carry the (opt-in)
transfer and are litesvm-tested. `gridtokenx-blockchain-core` exposes helpers to build the
account group.

**But REC never moves in production**, and it is *not* a wiring/config gap — it is an
escrow-model incompatibility:

- The REC transfer moves REC *seller → buyer*, so it assumes **per-party** REC holdings.
- `settle_offchain_match` has them: `[b"escrow", user, rec_mint]` PDAs, authority =
  `market_authority` PDA. The transfer is real and tested there.
- The **production** path is `execute_atomic_settlement`, which uses a **platform-pooled
  custodial** escrow model (`gridtokenx-trading-service/.../blockchain/settlement.rs`):
  every escrow is `ATA(platform, mint)`, and `escrow_authority == market_authority ==
  platform` (one bridge signature; parties are custodial and hold nothing on chain).
- In that model `seller_rec_escrow` and `buyer_rec_escrow` **both derive to
  `ATA(platform, rec_mint)` — the same account** — so the REC transfer is a
  platform→platform **no-op**.

So the two settlement models cannot both carry a *transfer-based* REC leg. A decision is
required.

## Options

### A. Migrate production settlement to the per-party model (`settle_offchain_match`)

Parties hold their own `[b"escrow", user, rec_mint]` (and energy/currency) escrows; the
`market_authority` PDA signs. The REC transfer already works here (tested).

- **Pros:** REC provenance is genuine on-chain per-party ownership — the stated goal (REC as
  "the provenance layer beneath the energy token"). No new on-chain mechanism. Reuses the
  proven, tested REC leg.
- **Cons:** Large operational change — production settlement moves from custodial-pooled to
  per-party escrows. Every party must have funded escrows before settle (a deposit/funding
  flow), and the one-bridge-signature simplicity is lost. Touches trading-service, the
  settlement orchestration, and the deposit UX.

### B1. Keep pooled custody; model REC as mint-to-buyer / burn-from-seller

Instead of transferring, burn REC from the seller side and mint to the buyer side.

- **Pros:** Compatible with pooled custody (no per-party escrows).
- **Cons:** REC mint/burn authority is the governance `poa_config` PDA, not trading — needs
  a cross-program authority path and a new instruction. Changes REC economics (supply churns
  every trade). And to represent "seller lost / buyer gained" it still needs a per-holder REC
  ledger somewhere — if the pool holds all REC, it collapses to the same no-op. Effectively
  re-introduces per-party accounting by another name.

### B2. Keep pooled custody; track REC provenance off-chain, reconcile on chain

Move REC ownership to an off-chain ledger (the platform already custodies funds); periodically
reconcile net positions on chain.

- **Pros:** No change to the on-chain settle path or custody model; cheapest to ship.
- **Cons:** Weakens the on-chain guarantee that was the entire point of tokenizing REC —
  provenance becomes a platform-trust claim, not a chain fact. The on-chain REC token becomes
  a periodic settlement artifact rather than the live source of truth.

## Recommendation

If **on-chain REC provenance is a core requirement** (it is the stated design intent), choose
**Option A** — it is the only option where REC ownership is a chain fact at trade granularity,
and it reuses the already-built, tested transfer. Scope it as a deliberate migration of
production settlement to per-party escrows (with a REC/energy/currency deposit flow), not a
patch onto the pooled path.

If the **custodial-pooled model must stay** for cost/UX reasons, **Option B2** is the pragmatic
choice (B1's mint/burn re-introduces per-party accounting without the provenance benefit) —
but accept that REC provenance is then a reconciled off-chain claim, and document that downgrade
explicitly.

**Not recommended:** bolting a transfer-based REC leg onto `execute_atomic_settlement` as-is —
it is a silent no-op (both escrows are the same platform ATA) and would give a false impression
that REC is being settled.

## What is already done (no decision needed)

- On-chain REC leg in both `settle_offchain_match` and `execute_atomic_settlement` (opt-in,
  tested; the latter is correct but only *usable* under a per-party model).
- `blockchain-core` helpers: `get_rec_mint_pubkey`, `rec_escrow_pubkey`,
  `rec_settlement_account_metas` (unit-tested).
- Order-time REC balance gate; `issue_erc` mint; `retire_rec` burn — all tested.
