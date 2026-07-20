# GridTokenX — Token System

> GRID, GRX, REC, and THBC — mint/burn mechanics, escrow, and atomic settlement.
> Status: **(impl)** on localnet · **(sim)** on-chain payment simulated · **(designed)** not yet built
> Last reviewed: 2026-07-17

---

## 1. Token Overview

| Token | Standard | Decimals | Mint authority | Role |
|---|---|---|---|---|
| **GRID** | SPL Token-2022 | 6 | Energy Token program (CPI); **AggregatorBridge SPIFFE role only** | Clearing asset — 1 GRID = 1 kWh of metered generation |
| **GRX** | SPL Token-2022 | 9 | Treasury / Registry programs | Collateral + yield staking + governance incentive |
| **REC** | SPL Token-2022 | 0 | Energy Token program; **AggregatorBridge SPIFFE role + ERC co-sign** | Renewable Energy Certificate — 1 REC = 1 verified kWh renewable |
| **THBC** | SPL Token-2022 | 6 | Treasury program | THB-pegged stablecoin; settlement denomination; reserve-attested |

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
EARN    DER sells P2P energy            → buyer pays GRID · seller receives GRID
SPEND   Buy energy in P2P market        → GRID transferred buyer → seller (via escrow)
BURN    Settlement vault                → escrowed GRID burned after atomic swap settles
```

---

## 3. GRX Token

Two independent staking systems share GRX as collateral — intentional, not duplication:

| System | Program | Purpose | Yield | Slashable |
|---|---|---|---|---|
| **Validator security bond** | `registry::stake_grx` | Aggregator node bond; minimum `MIN_VALIDATOR_STAKE = 10,000 GRX` | ❌ None | ✅ Yes |
| **Yield staking** | `treasury::stake_grx` | MasterChef rewards from swap fees | ✅ Yes | ❌ No |

A user may hold positions in both simultaneously. Separate vaults: `[b"grx_vault"]` (registry bond) vs `[b"stake_vault"]` (treasury yield).

### GRX ↔ THBC Swap

```
swap_grx_to_thbc:
    rate = reserve_attested_rate
    thbc_out = grx_in × rate
    require!(total_thbc_supply + thbc_out ≤ reserve_attested_thbc)  // peg ceiling
    transfer grx_in → swap_vault
    mint thbc_out → caller

redeem_thbc:
    grx_out = thbc_in / rate
    require!(grx_out ≤ swap_vault.balance)  // collateral bound
    burn thbc_in
    transfer grx_out ← swap_vault → caller
```

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

---

## 6. Atomic Escrow Mechanism (impl — simulated)

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
