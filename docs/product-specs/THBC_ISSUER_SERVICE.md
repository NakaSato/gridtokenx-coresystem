# THBC Settlement Service — Specification

**Path:** `docs/product-specs/THBC_ISSUER_SERVICE.md`
**Status:** design + simulation. Not deployed. No fiat held. No licence held.
**Supersedes:** `gTHB_ISSUER_SERVICE.md` (deleted), all `THBG` references in
`docs/blockchain-tokens.md`, `docs/blockchain-smart-contracts.md`, `CLAUDE.md`, `docs/glossary.md`.
**Implementation:** [`gridtokenx-thbc-service/`](../../gridtokenx-thbc-service/) — off-chain services only
(§9). See its [`ARCHITECTURE.md`](../../gridtokenx-thbc-service/ARCHITECTURE.md).
**Version:** 1.0 · 2026-07-29

---

## 0. Scope

This document specifies the payment leg of GridTokenX: how Thai baht enters and leaves the ledger,
what the on-chain unit means, and what is and is not guaranteed. It covers four services:

| Service | §  | On-chain effect |
|---|---|---|
| Fiat deposit (on-ramp) | §5 | `issue_thbc` — mint |
| Fiat withdrawal (off-ramp) | §6 | `redeem_thbc_for_fiat` — burn |
| Currency exchange | §7 | `exchange_grx_for_thbc` / `exchange_thbc_for_grx` — transfer only |
| Send / receive | §8 | SPL transfer |

Energy-trade settlement (`GRID ↔ THBC` inside `settle_offchain_match`) is specified in
`docs/master-architecture-v3.md` §2 and referenced here only where it constrains the payment leg.

---

## 1. Definition

> **THBC** is a Thai-baht-referenced settlement token. One unit represents a claim on one Thai baht
> held in a segregated reserve account at a licensed financial institution. THBC is issued against
> fiat received and burned against fiat paid, by a **licensed issuer partner**. GridTokenX operates
> the ledger integration and the settlement logic. GridTokenX is not the issuer, holds no fiat, and
> holds no user keys.

| Property | Value |
|---|---|
| Symbol | `THBC` (the only symbol; `gTHB` and `THBG` are retired) |
| Decimals | 6 |
| Token program | SPL Token-2022 |
| Mint | PDA `[b"thbc_mint"]`, authority = treasury PDA `[b"treasury"]` |
| Reference asset | THB, 1:1 |
| Redemption right | to THB, at par, on demand *(design intent; see §6.4 for the open gap)* |
| Backing set | Thai baht only. No volatile asset, ever. |

**THBC is not:** an investment product, a stake in GridTokenX, a claim on energy, or a token
GridTokenX issues. It is a payment instrument denominated in baht.

---

## 2. Invariants

These are the contract. A change that breaks one is a defect regardless of how clean it is.

| # | Name | Statement | Enforced | Status |
|---|---|---|---|---|
| **F1** | Reserve sufficiency | `thbc_supply ≤ attested_reserve` at all times | on-chain, `issue_thbc` | implemented |
| **F2** | Issuance conservation | `Σ issued − Σ redeemed = thbc_supply` | on-chain accounting | implemented |
| **F3** | Deposit idempotency | one confirmed `bank_ref` ⇒ at most one issuance | nullifier PDA | implemented |
| **F4** | Burn-before-wire | on-chain burn confirmed **≺** fiat payout enqueued | issuer state machine | design only |
| **F5** | Attestation freshness | `now − attestation_ts ≤ attestation_ttl`, else issuance halts | on-chain | implemented |
| **F6** | Backing-set purity | collateral backing THBC is fiat only | exchange path holds inventory, does not mint | **fix pending** |
| **F7** | Redemption liveness | an honest holder obtains fiat or recovers THBC within Δ | timelocked redemption escrow | **open — see §6.4** |
| **F8** | Non-custody | no GridTokenX key appears in a signer set that can move user THBC | escrow PDA design | implemented |
| **F9** | Attestation independence | the attestor key ≠ the parameter-admin key | on-chain key separation | implemented |

F1, F3 and F5 are enforced in `programs/treasury`, all three on `issue_thbc`. **F2, F4, F6 and F7
are not yet satisfied and are disclosed in `KNOWN_LIMITATIONS.md`.** Do not claim them.

> **Implementation note (2026-07-29, revised after the F6 fix).** The status column above is
> the *design* target. The authoritative runtime status is
> [`gridtokenx-thbc-service/crates/thbc-core/src/invariant.rs`](../../gridtokenx-thbc-service/crates/thbc-core/src/invariant.rs),
> served at `GET /v1/admin/invariants`. When this table and the registry disagree, the
> registry is right.
>
> **F6 is fixed in code.** `swap_grx_for_thbc` / `redeem_thbc_for_grx` were replaced by
> `exchange_grx_for_thbc` / `exchange_thbc_for_grx`, which transfer against a
> `[b"thbc_inventory"]` vault. There is no `mint_to` or `burn` of THBC left in any program.
> It is still `Partial`, not `Enforced` — code vs *state*: THBC minted by the old swap is
> still outstanding on any chain that ran it, and that supply is GRX-backed.
>
> **That fix briefly made F1 and F5 unenforceable, and `issue_thbc` restored them.** Both
> guards had lived on the minting swap — the `attested_reserve` ceiling (`PegBreach`) and the
> attestation-freshness check (`StaleAttestation`). With the swap gone they had zero call
> sites, and `attested_reserve` was written by `update_attestation` but never read for a
> check. Nothing minted THBC at all, so neither invariant could be *violated* — but
> "vacuously true because the operation does not exist" is not a guarantee.
>
> `issue_thbc` (gridtokenx-anchor `a554499`) is now the only instruction that increases
> supply, and it carries **F5 then F1** in that order — a stale `attested_reserve` makes the
> F1 comparison meaningless rather than merely conservative, so freshness is checked first.
> It also carries **F3**: the `[b"deposit", H(bank_ref)]` nullifier is created with Anchor
> `init` in the *same instruction* as the mint, so a replay is rejected by the Solana runtime
> at the account level before any program code runs. That is why F3 is `Enforced` with
> enforcement `Runtime` rather than `OnChain` — the guarantee comes from account existence,
> not from a `require!` the program could get wrong.
>
> Consequence for §2's table: **F1 is `Partial`, F3, F5, F8 and F9 are guarantees today.**
> F1 stays `Partial` because the on-chain ceiling is `attested_reserve`, not
> `attested_reserve − reserve_encumbered` as §4.1 specifies — `reserve_encumbered` does not
> fit in the 14 spare padding bytes on the zero-copy `Treasury`. The service enforces the
> tighter ceiling off-chain and is therefore *stricter than the chain*; a caller that
> bypasses it gets the looser one. F2 and F4 remain `Partial`.
>
> **The mint path is reachable off-chain as of this change.** `issue_thbc` is routed over
> `chain.tx.issuethbc`, so `LedgerPort::issue` no longer returns 501. `update_attestation`
> is routed too — it had been published to `chain.tx.attest` since before any consumer
> pulled that subject, so every attestation was captured by the bridge's stream and silently
> aged out. An instruction existing on-chain was never sufficient; it needed a route.
>
> THBC still comes into existence only against fiat: the inventory vault the exchange path
> pays out of is funded by transferring existing THBC in, never by minting.

---

## 3. Actors and trust

| Actor | Role | Trusted for | Can it steal? |
|---|---|---|---|
| `U` — prosumer / consumer | holds and transfers THBC | nothing | — |
| `B` — licensed issuer / bank | fiat custody; mint and burn authority | fiat custody, honest issuance | **yes** — can mint unbacked THBC or refuse redemption |
| `A` — reserve attestor | writes `attested_reserve` on-chain | reporting `R(t)` honestly | **yes** — inflating `R` lifts the F1 ceiling |
| `P` — GridTokenX platform | bridges, matcher, APIs | **liveness only** | no (F8) |
| `E` — ERC / regulator | read-only observer node | nothing | no |

**The load-bearing trust assumption is `A`.** `attested_reserve` is a single `u64` written by a
single signer, and every downstream guarantee — F1, F5, the peg claim, the solvency of every user
balance — reduces to that number being honest. This is structurally identical to the meter-oracle
assumption at the physical boundary and must be stated with the same candour. See
`THBC_SETTLEMENT_LAYER_DESIGN.md` §D for the research programme that attacks it.

`B` and `A` should not be the same entity. In the current simulation they are, which is a further
disclosed limitation.

---

## 4. On-chain surface

### 4.1 Treasury state (additions and changes)

```rust
pub struct Treasury {
    // existing
    pub authority: Pubkey,            // params, pause          (must ≠ attestor, F9)
    pub attestor: Pubkey,             // reserve attestation    (must ≠ authority, F9)
    pub grx_mint: Pubkey,
    pub thbc_mint: Pubkey,
    pub settlement_recorder: Pubkey,

    pub attested_reserve: u64,        // THB in segregated accounts, minor units — F1 ceiling
    pub attestation_ts: i64,
    pub attestation_ttl: i64,         // F5
    pub thbc_supply: u64,             // F1, F2
    pub grx_per_thbc_rate: u64,       // exchange rate — NOT a peg parameter
    pub total_settled_thbc: u64,

    // NEW
    pub issuer: Pubkey,               // licensed partner; sole caller of issue_thbc / redeem
    pub thbc_inventory: u64,          // platform-held THBC available to the exchange path
    pub reserve_encumbered: u64,      // fiat received but not yet issued (failed/pending KYC)
    pub redemption_queue_len: u32,    // pending redemptions — regulator-observable (§6.4)
}
```

`reserve_encumbered` exists because a deposit that clears the bank but fails KYC leaves fiat sitting
in the reserve account backing nothing. Without this field `attested_reserve` overstates free
backing and F1 becomes a weaker statement than it appears. Effective ceiling:

```
thbc_supply ≤ attested_reserve − reserve_encumbered
```

> **Implementation note.** None of the four NEW fields exist. `Treasury` is `#[account(zero_copy)]`
> and hand-padded to 272 bytes (`programs/treasury/src/state.rs:29`), so adding them is a layout
> change requiring a re-pad and re-initialisation. Until then, `gridtokenx-thbc-service` tracks
> `reserve_encumbered` in **its own** deposit records and enforces the tighter ceiling off-chain —
> making the service stricter than the chain. That asymmetry is a gap, not a safety margin: a
> caller that bypasses the service gets the looser on-chain ceiling.

### 4.2 Instructions

| Instruction | Signer | Effect | Invariants |
|---|---|---|---|
| `issue_thbc(amount, bank_ref_hash)` | `issuer` | mint → user; create nullifier PDA | F1, F2, F3, F5 |
| `redeem_thbc_for_fiat(amount)` | `user` | burn; enqueue redemption record | F2, F4 |
| `confirm_redemption(id)` | `issuer` | mark wire sent; decrement queue | F4 |
| `reclaim_redemption(id)` | `user` | after Δ with no confirm: re-mint to user | F7 |
| `exchange_grx_for_thbc(grx_in)` | `user` | GRX → vault; THBC **from inventory** | F6 |
| `exchange_thbc_for_grx(thbc_in)` | `user` | THBC → inventory; GRX from vault | F6 |
| `update_attestation(reserve)` | `attestor` | refresh `attested_reserve`, `attestation_ts` | F5, F9 |
| `set_params(...)` | `authority` | rate, fee, ttl, pause | F9 |
| `record_settlement*` | trading CPI | accounting only, moves nothing | — |
| `stake_grx` / `unstake_grx` / `claim_rewards` | `user` | GRX yield staking, separate vault | — |

**`exchange_*` must never call `mint_to` or `burn`.** That is the whole of the F6 fix. Supply
changes only through `issue_thbc` and `redeem_thbc_for_fiat`.

### 4.3 PDAs

| PDA | Seeds | Purpose |
|---|---|---|
| Treasury | `[b"treasury"]` | global state; mint + vault signer |
| THBC mint | `[b"thbc_mint"]` | the mint |
| Swap vault | `[b"swap_vault"]` | GRX held against exchange |
| Inventory vault | `[b"thbc_inventory"]` | platform-held THBC for exchange — **new** |
| Deposit nullifier | `[b"deposit", H(bank_ref)]` | F3 — **new** |
| Redemption record | `[b"redeem", user, seq]` | F4, F7 — **new** |
| Stake vault / reward vault | `[b"stake_vault"]`, `[b"reward_vault"]` | staking; never backs the peg |

---

## 5. Fiat deposit (on-ramp)

### 5.1 Flow

```
1. U initiates THB transfer to B's segregated account, memo = deposit_intent_id
2. B webhook → partner-api (mTLS, signature-verified)         [UNTRUSTED INPUT]
3. compliance-service: KYC status, sanctions screen, risk score
4. reserve-service: R(t) increases; A re-attests via update_attestation
5. chain-bridge: issue_thbc(amount, H(bank_ref))
     └── creates [b"deposit", H(bank_ref)] with `init` in the SAME instruction
```

### 5.2 Ordering constraint

Step 4 **must** precede step 5. If issuance precedes attestation, F1 is violated for the interval
between them. If attestation cannot be made synchronous, the correct construction is a pre-funded
reserve buffer so that `attested_reserve` already exceeds `thbc_supply + amount` before step 5, and
the buffer size is the documented bound on the violation window. State the bound; do not leave it
implicit.

### 5.3 Idempotency (F3)

The bank webhook is at-least-once. `bank_ref` is the bank's own unique transaction reference.
Creating `[b"deposit", H(bank_ref)]` with Anchor `init` in the same instruction as the mint makes a
replay revert at the account level, not the application level — the runtime rejects it, so no
application bug can defeat it.

This is deliberately the same construction as `[b"gen_mint", meter, window]` on the meter path. Both
boundaries convert an at-least-once off-chain event into an exactly-once on-chain effect, and both
use an account-existence nullifier to do it. Reusing the construction is the point.

> **Implementation note.** `H` is SHA-256 over the **normalised** reference — trimmed and
> upper-cased (`crates/thbc-core/src/bank_ref.rs`). Normalisation matters: a bank that echoes
> `"tx-001"` on retry and `"TX-001 "` on reconcile would otherwise hash to two different nullifiers
> and defeat F3 without anyone doing anything wrong. The service also enforces a `PRIMARY KEY` on
> `bank_ref_hash`, which stops replays **through this service only** — it is not the
> account-level guarantee and must not be reported as F3.

### 5.4 Failure modes

| Failure | Handling |
|---|---|
| Fiat clears, KYC fails | no issuance; `reserve_encumbered += amount`; return wire queued |
| Webhook replay | nullifier PDA reverts (F3) |
| Webhook forged | mTLS + signature verification at `partner-api`; webhook is untrusted input regardless |
| Attestation stale at step 5 | `issue_thbc` reverts on F5; deposit held, retried after refresh |
| Amount mismatch bank vs webhook | reconciliation-service raises; no issuance until resolved |

---

## 6. Fiat withdrawal (off-ramp)

### 6.1 Flow

```
1. U signs redeem_thbc_for_fiat(x)      — user-signed; B cannot burn on U's behalf
2. burn executes; [b"redeem", user, seq] record created; redemption_queue_len += 1
3. ───── BARRIER: nothing below runs before step 2 is CONFIRMED ─────
4. burn-service enqueues THB payout to U's verified bank account
5. B wires; issuer calls confirm_redemption(id); R(t) decreases; A re-attests
```

### 6.2 F4 — burn-before-wire

Fiat never leaves ahead of token destruction. The barrier is confirmation, not RPC acceptance —
the same rule as `build_and_submit_generation_mint`, which replies success only on
`ConfirmOutcome::Confirmed`. Do not weaken it to accept-on-send.

### 6.3 F7 — redemption liveness

Steps 1–2 are irreversible and on-chain. Steps 4–5 are a promise by `B`. If `B` declines, the user
has destroyed their token and received nothing.

Mitigation implemented at the token layer: `redeem_thbc_for_fiat` does **not** burn to zero
immediately. It moves the amount into a redemption record that is timelocked for Δ. If
`confirm_redemption` has not been called by Δ, the user calls `reclaim_redemption` and the THBC is
restored. The user is then no worse off than before, and `B`'s failure is visible on-chain.

```
t=0   redeem_thbc_for_fiat  → record created, tokens escrowed, queue_len++
t<Δ   confirm_redemption    → tokens burned, supply decremented, queue_len--
t≥Δ   reclaim_redemption    → tokens returned to user, queue_len--
```

`redemption_queue_len` and the individual records are readable by `E` (the ERC observer node), so
an issuer sitting on redemptions is publicly observable without anyone gaining custody.

> **Implementation note.** Δ runs from the moment the escrow **confirms**, not from the request:
> time spent waiting for the chain is not the issuer's to spend. A redemption in `payout_queued`
> is still reclaimable — the service having *queued* a payout is not evidence `B` ever sent one,
> and the holder's recovery right cannot depend on the issuer's own bookkeeping. The service
> cannot reclaim on a holder's behalf: `reclaim_redemption` is user-signed, and holding the key
> to call it is exactly what F8 forbids. `sweep_reclaimable` therefore reports, and the holder acts.

### 6.4 What this still does not solve

The escrow protects the *token* side. The *fiat* side remains a promise: if `B` takes the fiat and
never wires, the user recovers their THBC but the reserve is short, and F1 is violated at the next
honest attestation. **This is a genuine unsolved gap and belongs in `KNOWN_LIMITATIONS.md`.** It is
fair exchange between an on-chain action and an off-chain one, which has a known impossibility
result without a trusted third party. The research question — what is the minimal trusted third
party, and can the regulator's existing observer node serve as it without gaining custody — is
stated in `THBC_SETTLEMENT_LAYER_DESIGN.md` §D.2(iv).

---

## 7. Currency exchange

### 7.1 What changed and why

The exchange path previously minted THBC against GRX collateral while consuming fiat-reserve
headroom. That put a volatile asset in the backing set of a fiat-referenced token and made the peg
a governance parameter. It is replaced by an inventory exchange:

```rust
// exchange_grx_for_thbc
let thbc_out = compute_exchange_grx_for_thbc(grx_in, rate, fee_bps)?;
require!(thbc_out <= t.thbc_inventory, TreasuryError::InsufficientInventory);

transfer_checked(grx_in,   user_grx_ata     -> swap_vault)?;       // user pays GRX
transfer_checked(thbc_out, thbc_inventory   -> user_thbc_ata)?;    // platform pays THBC

t.thbc_inventory -= thbc_out;    // supply UNCHANGED — no mint, no burn
```

`thbc_supply` and `attested_reserve` are untouched. F1 and F6 are both preserved by construction.

### 7.2 Risk moves, it does not disappear

The platform now carries GRX inventory risk explicitly on its own balance sheet instead of
implicitly on the reserve. That is the correct place for it. `grx_per_thbc_rate` is an admin
parameter and remains a disclosed centralisation: the platform sets the price at which it will
exchange its own inventory. It is a quoted market-maker rate, not a peg.

### 7.3 No AMM

A constant-product pool holding THBC would put a fiat-referenced liability into a price-discovery
mechanism the platform does not control, making the reference rate a market outcome. Quoted rate
against bounded inventory only.

> **Implementation note (2026-07-29). Both halves are now done.**
>
> Off-chain, `crates/thbc-core/src/exchange.rs` prices identically to the on-chain math so
> quotes match execution to the minor unit, checks `thbc_out ≤ inventory` instead of
> `new_supply ≤ attested_reserve`, and never consumes reserve headroom. `ExchangeQuote` carries
> no field that could express a supply change, so no caller can request one.
>
> On-chain, `compute_exchange_grx_for_thbc` / `compute_exchange_thbc_for_grx` replaced the
> minting pair. Pricing is unchanged; the bound moved from reserve headroom to
> `inventory_vault.amount`, and the `new_supply` return is **gone rather than zeroed** — the
> function cannot tell a caller what supply to write because there is none. The inventory vault
> is `[b"thbc_inventory"]`, created by `initialize_thbc_inventory`; its **balance is the
> inventory**, with no mirrored `thbc_inventory: u64` counter that could drift from it. The
> bump was carved out of `Treasury._padding`, so the account is still 272 bytes and **no
> migration or re-init was needed**.
>
> Two deliberate deviations from this section as written: the attestation-freshness check is
> **absent** from the exchange path (F5 guards issuance; exchange issues nothing, so keeping it
> would cost liveness for no safety), and the reverse direction now **charges the same
> `swap_fee_bps` spread** as the forward one — the old `redeem_thbc_for_grx` was free, which
> made a round trip cost the forward fee only.

---

## 8. Send / receive

Plain SPL Token-2022 transfer between user wallets. Three constraints:

1. **Travel Rule.** Transfers above the regulatory threshold require originator and beneficiary
   information transmitted alongside. This is off-chain metadata bound to an on-chain transfer —
   an authenticated-channel problem, not a token-program problem.
2. **Freeze authority.** A regulated fiat-referenced token requires it. This directly contradicts
   any "user sovereignty" claim. The system takes the regulated side; do not claim both.
3. **Token-2022 composition constraint.** Confidential Transfer and Transfer Hook **do not
   compose**. The mint may have amount-confidential transfers *or* an on-transfer compliance hook,
   not both. This design chooses the hook. The consequence — settlement amounts are public, so a
   sealed-bid auction's clearing quantity is recoverable from the payment leg — is an accepted
   limitation of the current design and the subject of §D.2(ii) of the design note.

---

## 9. Off-chain services

| Service | Responsibility |
|---|---|
| `issuance-service` | idempotent issue state machine; nullifier construction |
| `redemption-service` | burn barrier, payout queue, Δ timer, reclaim monitoring |
| `compliance-service` | KYC (NDID primary), sanctions, AML risk, Travel Rule payloads |
| `reserve-service` | attestation cadence, `reserve_encumbered` accounting |
| `reconciliation-service` | `Σ issued − Σ redeemed = thbc_supply` (F2) checked hourly and daily |
| `treasury-service` | THBC inventory, GRX inventory, rate quoting |
| `chain-bridge` | sole path to the ledger — one door, policy-gated, hash-chained audit log |

Gateways: `public-api` (JWT), `partner-api` (mTLS + allowlist, bank webhooks), `admin-api`
(SSO + MFA + 4-eyes, includes the `E` regulator read surface).

All privileged actions are signed, appended to the hash-chained audit log, and replayable. No
service holds Solana RPC directly. No user private key is held server-side.

> **Implementation note.** These are modules of one deployable
> ([`gridtokenx-thbc-service`](../../gridtokenx-thbc-service/)), not six processes — they share a
> database and a ledger connection, and splitting them would buy distributed-transaction problems
> across the F4 barrier for no isolation benefit. The three gateways are three routers with
> distinct path prefixes so APISIX can apply a different auth policy to each; **the service itself
> authenticates nothing**, so exposing its port without APISIX in front publishes the admin
> surface. `compliance-service` has no KYC adapter and there is no payout queue behind
> `redemption-service` (§12): in non-simulated mode both refuse rather than auto-pass. The
> hash-chained audit log is **not implemented**.

---

## 10. Threat model

| # | Adversary | Capability | Mitigation | Residual |
|---|---|---|---|---|
| T1 | Malicious attestor `A` | inflates `attested_reserve` | key separation from `authority` (F9); attestation events public | **unmitigated** — single signer; needs threshold or proof of reserves |
| T2 | Malicious issuer `B` | mints unbacked THBC | F1 ceiling bounds it to `attested_reserve` | collusion of `A` + `B` defeats F1 entirely |
| T3 | Malicious issuer `B` | refuses redemption | Δ-timelock reclaim (F7); public queue | fiat still lost if `B` took it (§6.4) |
| T4 | Compromised platform `P` | attempts to move user THBC | F8 — `P` not in any user signer set | `P` can censor (liveness), not steal |
| T5 | Replayed bank webhook | double issuance | F3 nullifier at account level | none |
| T6 | Forged bank webhook | issuance with no fiat | mTLS + signature verify; treated as untrusted input | compromised bank key defeats it |
| T7 | Ledger observer | recovers auction clearing quantities from settlement amounts | none in current design | **accepted** — see §8.3 |

**T1 + T2 collusion is the system's single point of failure and no on-chain mechanism in this
design addresses it.** Say so.

> **Implementation note.** T5's mitigation is the on-chain nullifier, which does not exist; the
> service's database `PRIMARY KEY` covers replays through this service and nothing else. T6's
> signature verification is **not implemented** — `partner-api` requires the
> `x-thbc-signature` header to be present but cannot verify it without a bank adapter, so it fails
> closed on absence and no more. What actually bounds a forged webhook is F1.

---

## 11. Regulatory posture

The Bank of Thailand's design study for baht-backed stablecoins is nearing completion: 1:1 peg,
full reserves in segregated accounts at licensed institutions, redemption right for holders,
reserve assets ring-fenced. Public hearings are expected by end-2026 with formal regulations in late
2026 or early 2027. Issuance is to be performed by licensed private entities. The first phase is
limited to financial institutions for settlement purposes only.

Consequences for this specification:

1. **GridTokenX is an integrator, not an issuer.** Issuance is a licensed activity.
2. **Retail prosumer holding and transfer of THBC is outside the current perimeter.** Any document
   that lists prosumers as THBC holders — including `docs/blockchain-node-network.md` — is
   describing a later phase and must say so.
3. **Full-reserve is the design target already.** F1 and F6 align with the anticipated requirement.
4. Cite the BoT consultation paper itself once published. Secondary press reporting is not adequate
   for a paper's regulatory section.

---

## 12. Implementation status

| Component | Status |
|---|---|
| `attested_reserve` ceiling (F1) | implemented on `issue_thbc`, against `attested_reserve` — **not** minus `reserve_encumbered` |
| Attestation freshness (F5) | implemented on `issue_thbc`, checked *before* F1 |
| Attestor / authority key separation (F9) | implemented |
| GRX↔THBC exchange | implemented — transfers from a `[b"thbc_inventory"]` vault, does not mint (F6 fixed) |
| Settlement accounting (`record_settlement*`) | implemented |
| GRX staking | implemented |
| `issue_thbc` | implemented on-chain **and routed** — `chain.tx.issuethbc` |
| `update_attestation` | implemented on-chain **and routed** — `chain.tx.attest` |
| `redeem_thbc_for_fiat` | on-chain; **no Chain Bridge route** — still 501 |
| Deposit nullifier (F3) | implemented — Anchor `init` on `[b"deposit", H(bank_ref)]`, same instruction as the mint |
| Redemption escrow + reclaim (F7) | **not implemented** |
| `reserve_encumbered` accounting | **not implemented** |
| Bank adapter, KYC adapter | **not implemented** |
| Fiat rail of any kind | **does not exist** |

Everything in §5, §6, and §9 is design. The prototype simulates the payment leg as an on-chain
token transfer on localnet. **No claim in this document about fiat should be read as describing
running code.**

> **Implementation note (2026-07-29).** Off-chain, in `gridtokenx-thbc-service`:
>
> | Component | Status |
> |---|---|
> | Domain model — money, F1–F9 registry, state machines, exchange math, reconciliation | implemented, 149 tests |
> | §9 services — issuance, redemption, reserve, reconciliation, treasury | implemented |
> | `reserve_encumbered` accounting | implemented **off-chain only** — the field is not on the treasury account |
> | Inventory exchange (F6 fix) | implemented **on-chain and off-chain** (2026-07-29) — no program mints or burns THBC any more |
> | Simulated ledger (the §12 prototype) | implemented — models §4 including the missing instructions |
> | Chain Bridge adapter | `issue` and `update_attestation` are live request/reply over JetStream; the three redemption methods and `snapshot` return `501 not_implemented` |
> | Bank adapter, KYC adapter, payout queue | **not implemented** — refuse in non-simulated mode |
> | Hash-chained audit log | **not implemented** |
>
> The §12 table above has been corrected for both changes that landed on 2026-07-29 — the F6
> fix (exchange transfers from an inventory vault, mints nothing) and `issue_thbc` (which
> re-attached F1 and F5 to the one instruction that increases supply, and added F3).
>
> **Two things are worth keeping separate when reading it.** An instruction existing on-chain
> and an instruction being *reachable* are different claims, and this document conflated them
> once already: `update_attestation` had existed for a long time and the adapter published to
> `chain.tx.attest`, but no Chain Bridge consumer pulled that subject, so every attestation
> was captured by the stream and silently aged out at `max_age`. Nothing logged it. The table
> now states routing separately from implementation, and the bridge fails at boot if a
> subject with a handler is pulled by no worker.
>
> The remaining honest gaps: F1's on-chain ceiling is `attested_reserve`, not
> `attested_reserve − reserve_encumbered` (no room on the zero-copy `Treasury`), so the
> service is stricter than the chain and a caller bypassing it gets the looser bound; and the
> redemption instructions have no route, so the off-ramp is still 501.

---

## 13. Invariant test plan

| Invariant | Test | Tool |
|---|---|---|
| F1 | supply never exceeds attested reserve across random issue/redeem sequences | proptest |
| F2 | `Σ issued − Σ redeemed = supply` after arbitrary interleaving | proptest |
| F3 | replayed `bank_ref` reverts | E2E, LiteSVM |
| F4 | wire never enqueued before confirmed burn | service integration test |
| F5 | issuance halts past TTL; resumes on refresh | LiteSVM |
| F6 | exchange path never changes `thbc_supply` | proptest invariant + CI grep for `mint_to` in `exchange_*.rs` |
| F7 | reclaim succeeds at `t ≥ Δ`; fails at `t < Δ`; confirm blocks reclaim | LiteSVM with clock warp |
| F8 | no platform key in any user-value signer set | static audit + negative test |
| F9 | `authority == attestor` is rejected at `initialize` | unit test |

Match the discipline already applied to I1–I4 on the meter path: full E2E coverage or an explicit
statement of partial coverage. Do not report an invariant as covered when only the happy path is
tested.

> **Implementation note — the explicit statement of partial coverage this section demands.**
>
> | Invariant | Planned tool | What actually runs |
> |---|---|---|
> | F1 | proptest | ✅ proptest + service integration |
> | F2 | proptest | ✅ proptest, cross-checked against the reconciler |
> | F3 | E2E, LiteSVM | ⚠️ **partial** — service-level replay only; the nullifier PDA does not exist, so there is nothing for LiteSVM to run |
> | F4 | service integration | ✅ full, including accept-on-send rejection and double-payout refusal |
> | F5 | LiteSVM | ⚠️ **partial** — against the simulator |
> | F6 | proptest + CI grep | ⚠️ proptest ✅; **the CI grep does not exist — this repo has no CI at all** (all 9 workflows deleted in `dfde2d8`) |
> | F7 | LiteSVM + clock warp | ⚠️ **partial** — simulator with clock warp; the escrow does not exist on-chain |
> | F8 | static audit + negative test | ✅ both |
> | F9 | unit test | ✅ |
>
> F3, F5 and F7 execute against `SimulatedLedger`, a model of the treasury *as specified*. That
> demonstrates the service and the domain model are correct. It demonstrates nothing about the
> chain, and for F3 and F7 the chain implements nothing to demonstrate.

---

## 14. Glossary delta

| Term | Definition |
|---|---|
| **THBC** | THB-referenced settlement token, 6 decimals, fully reserved, issued by a licensed partner. The only baht symbol in this system. |
| ~~gTHB~~ | Retired. Was the fiat-reserved design. Now THBC. |
| ~~THBG~~ | Retired. Was the GRX-collateralised mint. That behaviour is removed, not renamed. |
| **Issuer (`B`)** | Licensed partner holding fiat and controlling mint/burn. Not GridTokenX. |
| **Attestor (`A`)** | Party writing `attested_reserve` on-chain. Must differ from the parameter admin. |
| **Inventory exchange** | GRX↔THBC against platform-held THBC. Never changes supply. |
| **Δ (redemption timeout)** | Period after which an unconfirmed redemption may be reclaimed by the holder. |
