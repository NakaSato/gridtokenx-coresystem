# Known Limitations

Things this system does **not** guarantee, stated plainly so no document, demo, or paper
claims otherwise.

> **Scope.** This file currently covers the **THBC payment leg only** — it was created
> to hold the disclosures [`docs/product-specs/THBC_ISSUER_SERVICE.md`](docs/product-specs/THBC_ISSUER_SERVICE.md)
> §2 and §6.4 require. Its silence on any other subsystem means nobody has written that
> section yet, **not** that the subsystem has no limitations.
>
> Last reviewed: 2026-07-29

---

## THBC payment leg

### The one-line version

**No fiat is held. No licence is held. No fiat rail of any kind exists.** Most of the
payment leg is design and simulation. Of nine invariants, **four** may be described as
guarantees. None is design-only — and **F8 (non-custody) has been retired**: the platform
is custodial by design, so the claim was never true. That one matters more than the rest
combined. See below.

The authoritative, machine-readable status is
[`gridtokenx-thbc-service/crates/thbc-core/src/invariant.rs`](gridtokenx-thbc-service/crates/thbc-core/src/invariant.rs),
served at `GET /v1/admin/invariants`. When prose and that registry disagree, the
registry is right.

### What may be claimed

| | Invariant | Enforced by |
| :-- | :-- | :-- |
| **F3** | Deposit idempotency — one `bank_ref`, at most one issuance | the Solana **runtime**: `[b"deposit", H(bank_ref)]` is created with `init` in the same instruction as the mint, so a replay is rejected at the account level before any program code runs |
| **F5** | Attestation freshness — issuance halts past the TTL | `issue_thbc`, checked before the F1 ceiling |
| **F7** | Redemption liveness — an honest holder recovers THBC within Δ | the escrow + Δ timelock; both terminal instructions `close` the record, so double-confirm and confirm-after-reclaim fail at the account level. **Token side only** — see §6.4 |
| **F9** | Attestation independence — attestor key ≠ parameter admin | the treasury program, at `initialize` |

F1 and F5 were enforced by nothing between the F6 fix and `issue_thbc` — both guards
lived on the minting swap that F6 deleted. That window is closed.

### ⚠️ F8 — the platform IS custodial. Do not claim otherwise.

**`gridtokenx-iam-service` can decrypt any user's Solana signing key unilaterally.**

It generates each user's keypair and stores it encrypted
(`gridtokenx-iam-service/crates/iam-logic/src/auth_service.rs:536`), but both KDF inputs
are **service configuration** — `encryption_secret` and `master_secret`
(`crates/iam-core/src/config.rs:31,45`, from `ENCRYPTION_SECRET` / `MASTER_SECRET`).
The user's password is **not** an input, and the PBKDF2 salt is stored alongside the
ciphertext. Anyone holding those two environment variables and the database can
reconstruct every user's keypair and sign as them.

Nothing decrypts those stored keys today — `decrypt_private_key*` is called only from
`gridtokenx-blockchain-core`'s own unit tests. That made this look like a latent risk
awaiting a decision. **It is not latent, and there is no decision to make: custody is
the platform's settled, documented architecture.**

- The IAM function is named `provision_custodial_wallet` and states the intent outright:
  *"custody is service-side by design so IAM can sign on the user's behalf"*
  (`crates/iam-logic/src/auth_service.rs:502,518`).
- `gridtokenx-blockchain-core` lists *"IAM stores encrypted custodial keys"* as a
  load-bearing invariant of the shared crate (`CLAUDE.md`, invariant 6).
- Per-user Ed25519 signing was **removed**, not planned. IAM's `SignMessage` RPC is
  gone, no `.proto` in the tree declares one, and `sign_message` fails loudly
  (`gridtokenx-trading-service/.../identity/mod.rs:48`).

And the platform's ability to move user assets is **exercised in production**, just with
a different key than the stored ones: `execute_atomic_settlement` signs for every party
with a single `platform_admin` Vault Transit key, and each escrow is
`ATA(platform, mint)` — see [`docs/proposed/rec-production-settlement.md`](docs/proposed/rec-production-settlement.md).
The per-user keys sitting in the IAM database are the unused residue of the capability
that was removed; deleting them would change nothing about F8.

This falsifies two things stated as design guarantees:

- Spec §3 actor table: *"`P` — GridTokenX platform … trusted for **liveness only** …
  Can it steal? **no** (F8)"*.
- Spec §10 threat model **T4**: *"Compromised platform `P` attempts to move user THBC →
  F8 → `P` can censor (liveness), not steal"*. `P` can steal.

What remains true, and is why this was missed: `gridtokenx-thbc-service` holds no user
key, and no method on any port in `thbc-core/src/ports.rs` accepts a keypair or signer.
That is a real property — of **one service**, not of GridTokenX.

**Resolution (2026-07-29): F8 is retired, not scheduled.** It described a system
GridTokenX is not and is not becoming. Restoring it would mean reinstating per-user
Ed25519 signing platform-wide — IAM `SignMessage` plus per-user Vault Transit keys —
which is the same blocker already recorded against Option A in
[`docs/proposed/rec-production-settlement.md`](docs/proposed/rec-production-settlement.md).
That is a platform-wide re-architecture with its own key-recovery story, not a
`gridtokenx-thbc-service` task.

Two consequences follow, and neither is optional:

1. **Custody must be disclosed to users**, not buried in an invariant table. A holder of
   THBC has a claim on GridTokenX's operational security, not on a key only they hold.
2. **Compromise of `P` is total loss of user assets.** The mitigation is operational —
   Vault, key rotation, HSM, separation of duties, audit — because there is no
   cryptographic barrier left to rely on.

The unused per-user keys in the IAM database remain worth deleting on data-retention
grounds (they are decryptable material serving no function), but that is hygiene, not an
F8 fix.

### What may not

| | Invariant | Status | The gap |
| :-- | :-- | :-- | :-- |
| **F1** | Reserve sufficiency | partial | Re-attached to `issue_thbc`, so `PegBreach` has a call site again. Still checked against `attested_reserve`, **not** `attested_reserve − reserve_encumbered` as §4.1 specifies — a `Pubkey`-sized field does not fit in the 14 spare padding bytes on the zero-copy `Treasury`. Fiat that cleared the bank then failed KYC still counts as free backing on-chain, so `gridtokenx-thbc-service` enforces the tighter ceiling from its own records and is **stricter than the chain**. |
| **F2** | Issuance conservation | partial | **Detective, not preventive.** Nothing rejects a write for breaking `Σ issued − Σ redeemed = supply`; the reconciler reports drift after the fact. It now runs on an interval (`THBC_RECONCILE_INTERVAL_SECS`, default hourly per §9) and appends every run to `reconciliation_runs`, so a breach that was later resolved stays visible. **Until 2026-07-29 there was no scheduler at all** and nothing wrote that table — §9's "checked hourly and daily" was true of no deployment. |
| **F4** | Burn-before-wire | partial | The ordering is enforced by the redemption state machine, which is the only route to a payout. But **there is no fiat rail behind it**, so the barrier has never been tested against a real payout queue. |
| **F6** | Backing-set purity | partial *(code fixed)* | `swap_grx_for_thbc`/`redeem_thbc_for_grx` were replaced by `exchange_grx_for_thbc`/`exchange_thbc_for_grx`, which transfer against a `[b"thbc_inventory"]` vault. **No program mints or burns THBC any more.** Still not claimable, and the distinction is code vs *state*: THBC already minted by the old swap is still outstanding on any chain that ran it, and that supply is GRX-backed. Retiring or re-initialising it is what turns this Enforced. |

### §6.4 — the gap that is not an implementation bug

The redemption escrow protects the *token* side. If `B` takes the fiat and never wires,
the holder reclaims their THBC after Δ and is no worse off in tokens — **but the reserve
is short, and F1 is violated at the next honest attestation.** No on-chain mechanism in
this design recovers the fiat.

This is fair exchange between an on-chain action and an off-chain one, which has a known
impossibility result without a trusted third party. It is a research question
(`THBC_SETTLEMENT_LAYER_DESIGN.md` §D.2(iv) — *note: that document does not exist yet*),
not a defect to be fixed in the service.

### T1 + T2 — the single point of failure

`attested_reserve` is a single `u64` written by a **single signer**. F1, F5, the peg
claim, and the solvency of every user balance all reduce to that number being honest.

- **T1** (dishonest attestor `A` inflates the reserve) is **unmitigated**. Key separation
  from `authority` (F9) is the only structural defence and it does not defend against a
  dishonest `A`. A threshold scheme or proof of reserves would; neither exists.
- **T2 + T1 collusion defeats F1 entirely.** No mechanism in this design addresses it.
- `B` and `A` **should** be different entities. In the current simulation they are the
  same.

### T6 — bank webhook signatures are not verified

`partner-api` requires the `x-thbc-signature` header to be *present* and cannot verify it,
because there is no bank adapter. What actually bounds a forged deposit is F1, not
authentication.

### T7 — settlement amounts are public

Token-2022 Confidential Transfer and Transfer Hook **do not compose**. This design chooses
the hook, so a sealed-bid auction's clearing quantity is recoverable from the payment leg.
Accepted, not mitigated.

### Not implemented at all

- Bank adapter · KYC/NDID adapter · sanctions and AML screening · Travel Rule payloads
- THB payout queue — any fiat rail whatsoever
- Hash-chained audit log
- `redeem_thbc_for_fiat` · `confirm_redemption` · `reclaim_redemption`
- A **distinct `issuer` key**: `issue_thbc` is gated on `Treasury.authority`, conflating the parameter admin with the issuer and weakening the §3 actor separation. Needs a layout change.
- Treasury fields `issuer`, `reserve_encumbered`, `redemption_queue_len` (`thbc_inventory` is a vault balance instead, deliberately)
- A Chain Bridge route for `issue_thbc`: the instruction exists on-chain, but this service publishes intents rather than building transactions, and the bridge has no handler yet

In non-simulated mode the compliance port and the payout port **refuse** rather than
auto-pass, so these gaps fail loudly instead of looking like working integrations.

### Test coverage is partial, and here is how

Spec §13 asks for LiteSVM on F3, F5 and F7. **F3, F5, F1 and F6 now have it**:
`gridtokenx-anchor/tests/treasury_thbc_litesvm.ts`, 14 cases against the compiled
program, in-process, no validator. It is mutation-checked — deleting the F5 guard kills
exactly the three F5 cases — so it demonstrably catches a regression rather than merely
passing.

**F7 now has it too** — reclaim fails at Δ−1 and succeeds at Δ, confirm blocks reclaim
forever, double-confirm and confirm-after-reclaim are both rejected, and pausing cannot
trap escrowed tokens. Also mutation-checked: deleting the timelock guard kills exactly
the Δ-boundary case.

§13 also asks for a CI grep for `mint_to` in `exchange_*.rs`. **There is no CI in this
repo** — all nine GitHub Actions workflows were deleted in `dfde2d8` (2026-07-01) and no
`.github/` directory exists. Every gate is manual; a green local run is the only signal.

### Regulatory

GridTokenX is an **integrator, not an issuer** — issuance is a licensed activity and no
licence is held. Retail prosumer holding and transfer of THBC is **outside the current
regulatory perimeter**; the Bank of Thailand's anticipated first phase is limited to
financial institutions for settlement purposes. Any document listing prosumers as THBC
holders — including [`docs/blockchain-node-network.md`](docs/blockchain-node-network.md) —
is describing a later phase and should say so.
