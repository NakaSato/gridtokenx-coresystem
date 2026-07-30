# GridTokenX — Token System

> GRID, GRX, REC, and THBC — mint/burn mechanics, escrow, and atomic settlement.
> Status: **(impl)** on localnet · **(sim)** on-chain payment simulated · **(designed)** not yet built
> Last reviewed: 2026-07-17

---

## 1. Token Overview

| Token | Standard | Decimals | Mint authority | Role |
|---|---|---|---|---|
| **GRID / GRX**<br>(one mint) | SPL Token-2022 | 9 | Energy Token program (CPI); **AggregatorBridge SPIFFE role only** | Clearing asset — 1 GRID = 1 kWh of metered generation. The same mint is called **GRX** in the treasury/registry programs (`grx_mint`) for its collateral/staking role. |
| **REC** | SPL Token-2022 | 0 | Energy Token program; **AggregatorBridge SPIFFE role + ERC co-sign** | Renewable Energy Certificate — 1 REC = 1 verified kWh renewable |
| **THBC** | SPL Token-2022 | 6 | Treasury program | THB-pegged stablecoin; settlement denomination; reserve-attested |

> **GRID and GRX are one SPL mint, not two.** The treasury derives its `grx_mint` from the
> energy-token program's canonical `[b"mint_2022"]` PDA — see
> [`scripts/init-treasury.ts:25`](../gridtokenx-anchor/scripts/init-treasury.ts) and the
> field comment at
> [`programs/treasury/src/state.rs:33`](../gridtokenx-anchor/programs/treasury/src/state.rs)
> ("GRX SPL mint (energy-token program)"). The two names mark two *roles* of one asset:
> **GRID** when it denominates kWh in the energy/clearing path, **GRX** when it is locked as
> collateral or staked. It carries **9 decimals** in both roles
> ([`initialize_token.rs:22`](../gridtokenx-anchor/programs/energy-token/src/instructions/initialize_token.rs)),
> so a kWh amount converts to atomic units with `× 1e9` — never `1e6`.

> **Network access:** All token operations occur on a private consortium SVM. There are no public endpoints. Minting, transfers, and swaps are accessible only to network-admitted participants holding valid mTLS certificates. See [`blockchain-node-network.md`](blockchain-node-network.md) for the network access model.

---

## 2. GRID Token

### What GRID Is

GRID is a **clearing asset**, not a data record. Minting creates something tradable — the unit that energy trades clear against. The mint is the *start of a settlement chain*, not a log entry.

```
1 GRID = 1 kWh of verified metered generation
```

### Mint Authority Restriction

**Mint authority: AggregatorBridge SPIFFE role (MEA/PEA Aggregator Bridge) only.**

The private LA#2 BidEngine SPIFFE role **cannot** call `mint_generation`. This restriction is enforced by Chain Bridge RBAC before the instruction reaches the chain. MEA and PEA are the only entities that operate the Aggregator Bridge with the AggregatorBridge SPIFFE role.

### Mint Flow

```
Smart Meter OBIS 2.8.0 export register
    │ Ed25519-signed · DLMS/COSEM · AES-256-GCM encrypted
    ▼
Aggregator Bridge — verify sig (fail-closed) · decrypt · aggregate 15-min window
    │  (operated by MEA or PEA; holds AggregatorBridge SPIFFE cert)
    ▼  NATS chain.tx.mint
Chain Bridge — RBAC check (AggregatorBridge role required) · dedup · Vault Transit sign
    │
    ▼  mint_generation instruction
Energy Token program
    ├── check GenerationMintRecord PDA (idempotency guard)
    ├── if PDA exists → no-op (already minted this window)
    └── if PDA absent → create PDA · mint GRID to owner wallet
```

**Idempotency double-lock:**

| Layer | Mechanism | Guards against |
|---|---|---|
| Off-chain | Redis `MINTED_SET` keyed by `(meter_id, epoch)` | Local retries, crash loops |
| On-chain | `GenerationMintRecord` PDA seeded by `[meter_id, register_reading, period]` | Two nodes racing; forged off-chain state |

### GRID Lifecycle

```
EARN    DER delivers kWh in DR event    → distribute_tokens mints GRID proportional to kWh
EARN    DER sells P2P energy            → seller delivers GRID · receives THBC
SPEND   Buy energy in P2P market        → GRID transferred seller → buyer (via escrow);
                                          THBC transferred buyer → seller (same instruction)
```

> **Energy moves seller → buyer; payment moves buyer → seller.** A P2P trade is one atomic
> two-leg swap, not a GRID-for-GRID transfer: the currency leg debits the buyer's THBC escrow
> and the energy leg credits the buyer's GRID escrow, in a single instruction. Verified in
> both settlement paths —
> [`settle_offchain.rs:853`](../gridtokenx-anchor/programs/trading/src/instructions/settle_offchain.rs)
> (`settle_offchain_match`) and
> [`programs/trading/src/lib.rs:724`](../gridtokenx-anchor/programs/trading/src/lib.rs)
> (`execute_atomic_settlement`). Settlement **transfers** GRID between escrows; it does not
> burn it — there is no `burn` in the trading program.

---

## 3. GRX — the Energy Mint in its Collateral Role

**GRX is not a second token.** It is the GRID mint (§1) under the name the treasury and
registry programs use for it. Staking or swapping "GRX" locks the very same asset that
denominates kWh.

Two independent staking systems share GRX as collateral — intentional, not duplication:

| System | Program | Purpose | Yield | Slashable |
|---|---|---|---|---|
| **Validator security bond** | `registry::stake_grx` | Aggregator node bond; minimum `MIN_VALIDATOR_STAKE = 10,000 GRX` | ❌ None | ✅ Yes |
| **Yield staking** | `treasury::stake_grx` | MasterChef rewards from swap fees | ✅ Yes | ❌ No |

A user may hold positions in both simultaneously. Separate vaults: `[b"grx_vault"]` (registry bond) vs `[b"stake_vault"]` (treasury yield).

### GRX ↔ THBC Swap

Because GRX is the energy mint, this swaps the **energy token for baht**. The rate field is
`grx_per_thbc_rate`, documented in-code as "THBC minor units issued per 1 whole GRX"
([`programs/treasury/src/state.rs:41`](../gridtokenx-anchor/programs/treasury/src/state.rs)),
i.e. a **baht-per-kWh** price. ⚠️ The identifier reads *GRX per THBC* but its comment and use
are *THBC per GRX* — trust the comment and the arithmetic below, not the name. Note also the
decimal asymmetry: GRX is 9-dec, THBC is 6-dec.

```
swap_grx_to_thbc:
    rate = reserve_attested_rate            // THBC minor units per 1 WHOLE GRX
    gross    = grx_in × rate / 1e9          // ÷ GRX_ATOMS_PER_WHOLE (GRX is 9-dec)
    fee      = gross × swap_fee_bps / 10_000
    thbc_out = gross − fee
    require!(total_thbc_supply + thbc_out ≤ reserve_attested_thbc)  // peg ceiling
    transfer grx_in → swap_vault
    mint thbc_out → caller

redeem_thbc:
    grx_out = thbc_in × 1e9 / rate          // × GRX_ATOMS_PER_WHOLE, inverse of above
    require!(grx_out ≤ swap_vault.balance)  // collateral bound
    burn thbc_in
    transfer grx_out ← swap_vault → caller
```

> The `1e9` factor is **not** cosmetic — it is the 9-decimal GRX atom normalization
> (`GRX_ATOMS_PER_WHOLE`, [`programs/treasury/src/lib.rs:41`](../gridtokenx-anchor/programs/treasury/src/lib.rs)).
> Omitting it misprices the exchange by 10⁹. See
> [`compute_exchange_grx_for_thbc`](../gridtokenx-anchor/programs/treasury/src/lib.rs)
> and `compute_exchange_thbc_for_grx` in the same file — formerly
> `compute_swap_grx_for_thbc` / `compute_redeem_thbc_for_grx`, renamed when the F6 fix
> made the exchange path a transfer against inventory instead of a mint/burn. **The
> pricing arithmetic is unchanged**; only the bound moved (from
> `new_supply <= attested_reserve` to `net <= inventory`), so the factor above still
> applies exactly as written.

---

## 4. REC (Renewable Energy Certificate)

**1 REC = 1 verified kWh from a renewable source (solar PV, wind, battery-charged-renewable).**

### REC Mint — Gated by Admitted Aggregator

```
mint_rec instruction:
    require!(rec_validator co-sign)   // admitted oracle aggregator must co-sign (AggregatorBridge role)
    require!(meter.device_type in [solar, wind, battery_renewable])
    create REC → owner wallet (non-duplicable SPL token)
```

REC is issued alongside GRID mint for qualifying generation. The two tokens are independent — REC can be transferred or retired separately.

**Co-sign authority:** The AggregatorBridge SPIFFE role (MEA/PEA) co-signs REC issuance. For T-REC (transmission-level REC), EGAT acts as the co-signer. Private LA#2 BidEngine role does **not** have REC mint co-sign authority.

### REC Lifecycle

```
ISSUE    Renewable DER generates kWh    → mint_rec → REC in owner wallet
TRADE    Owner sells REC to another party   → SPL transfer
RETIRE   Burn REC                       → proof of renewable consumption (corporate reporting)
```

**REC is the cleanest blockchain use case** in GridTokenX: ownership must be non-duplicable and transferable, which a ledger does well, with firm regulatory standing (Thai SEC Group 1 — not electricity, so ESB restriction does not apply).

---

## 5. THBC (THB-Pegged Stablecoin)

THBC is the settlement denomination — the "payment" side of the atomic energy trade.

```
Peg: 1 THBC ≈ 1 THB
Issuer: Treasury program (reserve-attested)
Reserve custodian: independent bank under BoT alignment (attestor role, separate from param admin)
THBC reserve attestation: Bank / BoT only — no other party (including LA#2) can attest
```

**Peg invariant (enforced on-chain):**
```
total_thbc_supply ≤ reserve_attested_thbc
```

> **Simulation note:** In this co-simulation, payment settles on-chain as a THBC swap — fully simulated on localnet. In a real deployment, fiat would settle off-chain through existing utility billing and the §97(4) fund. Both paths are architecturally supported; only the simulated on-chain path is implemented. (v3 §II.2)

### Which mint the trading service actually settles in

Trading settles in whatever `CURRENCY_TOKEN_MINT` names — that is **not** automatically the
treasury's THBC mint, and the difference is invisible from the trade itself.

Until 2026-07-30 this pointed at a dev-minted classic-SPL token whose mint authority was the
platform dev wallet: no reserve backing, no attestation, and none of F1/F3/F5/F7. The
treasury's real THBC (`[b"thbc_mint"]`, mint authority = the treasury PDA) had **zero
supply** — nothing had ever been issued — while the trading `Market.settlement_thbc_mint`
already pointed at it. Trades therefore settled in a stand-in while the on-chain config
claimed otherwise.

To settle in real THBC, four things must line up:

1. **Supply must exist.** `issue_thbc` is the only instruction that raises `thbc_supply`, and
   it checks F5 (attestation freshness) *before* F1 (`supply + amount ≤ attested_reserve −
   reserve_encumbered`). A treasury that has never been attested has `attestation_ts = 0`,
   which is permanently stale — so `update_attestation` must run first
   (`gridtokenx-anchor/scripts/issue-thbc.ts` does both, in that order).
2. **`CURRENCY_TOKEN_MINT`** = the treasury THBC mint.
3. **`CURRENCY_TOKEN_PROGRAM=token2022`.** THBC is Token-2022 while the legacy stand-in was
   classic SPL, and an ATA derived under the wrong program is a *different address*. The
   on-chain context takes the two token programs separately (`token_program` for the currency
   accounts, `secondary_token_program` for energy) and constrains the currency accounts with
   `owner = token_program.key()`, so the wrong program fails with Anchor `ConstraintOwner`
   (2004) — not with anything that names the mint. Defaults to classic SPL so existing
   deployments are unaffected.
4. **Collector accounts must pre-exist.** The settlement path creates the seller's currency
   ATA and the buyer's energy ATA idempotently, but the fee/wheeling/loss collector ATAs are
   only *derived* — a missing one fails the settlement.

> `total_settled_thbc` stays **0** even after this. The treasury `record_settlement` CPI is
> mandatory only on `settle_offchain_match`; the live path is `execute_atomic_settlement`,
> which has no treasury CPI at all. Settling *in* THBC and *recording* to the treasury are
> two different things.

---

## 6. Atomic Escrow Mechanism (impl — simulated)

> **What runs today is atomic but NOT party-authorized — do not cite this section as the
> live settlement model.** The trading service settles through `execute_atomic_settlement`
> (context inlined at `gridtokenx-anchor/programs/trading/src/lib.rs:969`), whose only
> `Signer` accounts are `escrow_authority` and `market_authority` — **both the platform**.
> The buyer never signs, the seller never signs, and the escrows are the platform's *pooled*
> ATAs rather than per-trade PDAs. Atomicity is real (one instruction, all-or-nothing across
> five `transfer_checked` CPIs, with a `[b"trade", trade_id]` nullifier blocking replay), so
> it protects against a **half-completed settlement** — but not against a compromised or
> malicious platform. That is the concrete form of the custody problem recorded as
> invariant **F8 = `Violated`** in
> `gridtokenx-thbc-service/crates/thbc-core/src/invariant.rs`.
>
> The both-peers-sign design below corresponds to `settle_offchain_match`, which verifies
> Ed25519-signed order payloads from each party through the instructions sysvar and is the
> path that also makes the treasury `record_settlement` CPI mandatory. **The trading service
> does not currently call it.** Moving to it is the single change that would make these swaps
> party-authorized instead of platform-authorized.

### The Problem

Two peers who do not trust each other must exchange GRID for THBC such that neither can take the other's asset without giving up their own. A naive two-step exchange (seller sends GRID, buyer sends THBC) fails: whoever moves second can defect.

### Escrow PDA

```
PDA: [b"escrow", trade_id]
Holds: seller_grid_amount · buyer_thbc_amount · seller · buyer · state
```

### Three Instructions

```
ix 1: open_escrow(trade_id, grid_amount, thbc_amount)
  - signers: matched seller AND buyer (or cleared order proves both)
  - moves seller's GRID  → escrow PDA (program-owned; neither peer controls)
  - moves buyer's THBC   → escrow PDA
  - state = FUNDED only when BOTH legs present
  - require!(both_legs_funded) — nothing left half-done

ix 2: settle_escrow(trade_id)
  - precondition: state == FUNDED
  - ONE instruction (atomic):
        escrow.GRID  → buyer
        escrow.THBC  → seller
  - state = SETTLED
  - either completes fully or the entire transaction reverts

ix 3: cancel_escrow(trade_id)
  - only if state == FUNDED + timeout/abort condition
  - returns each leg to original owner exactly
  - state = CANCELLED
```

### Why This Is Atomic

Atomicity comes from Solana's transaction model: an instruction either completes fully or the entire transaction reverts and no account changes persist. In `settle_escrow`, both transfers are in **one instruction** — there is no state where GRID has moved to the buyer but THBC has not reached the seller.

The escrow PDA is **program-owned** between funding and settlement. Neither peer nor the LA can withdraw unilaterally. The LA operates the matching that produces `trade_id` but is **not a signer on the escrow**.

### Escrow Invariants

| Invariant | Enforcement |
|---|---|
| No half-settlement | Both transfers in one instruction; revert-on-failure |
| No unilateral withdrawal | Escrow PDA program-owned; peers cannot sign its outflow |
| LA non-custody | LA key absent from escrow signer set |
| Conservation | Settled amounts = escrowed amounts (no value created or destroyed) |
| No double-settle | `FUNDED → SETTLED` is one-way; re-call is a no-op |
| Refund safety | Cancel returns exact original legs |

### Why DR Has No Escrow

The DR service has no escrow because there is nothing to swap atomically: the §97(4) fund pays the participant one-directionally, off-chain. No counterparty asset to hold against, no defection risk, therefore no need for the trustless mechanism. The absence of escrow in DR is correct, not a gap.

---

## 7. Token Flows Summary

```
DR event (wholesale):
    DER kWh delivered → Aggregator Bridge M&V → DR Settlement (on-chain record)
    §97(4) fund pays off-chain → disbursement record on-chain
    GRID minted proportional to kWh → DER owner wallets
      (AggregatorBridge SPIFFE role required; LA#2 BidEngine cannot mint)
    REC minted → DER owner wallets (if renewable)

P2P trade (retail):
    Buyer → open_escrow (THBC leg)
    Seller → open_escrow (GRID leg)
    Both legs funded → settle_escrow (atomic)
    GRID → Buyer wallet
    THBC → Seller wallet
    REC → Seller wallet (if renewable generation)
```
