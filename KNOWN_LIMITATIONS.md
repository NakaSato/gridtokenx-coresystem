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
payment leg is design and simulation. Of nine invariants, **two** may be described as
guarantees.

The authoritative, machine-readable status is
[`gridtokenx-thbc-service/crates/thbc-core/src/invariant.rs`](gridtokenx-thbc-service/crates/thbc-core/src/invariant.rs),
served at `GET /v1/admin/invariants`. When prose and that registry disagree, the
registry is right.

### What may be claimed

| | Invariant | Enforced by |
| :-- | :-- | :-- |
| **F8** | Non-custody — no GridTokenX key can move user THBC | structural; no port accepts a user key |
| **F9** | Attestation independence — attestor key ≠ parameter admin | the treasury program, at `initialize` |

Both survivors are **structural** rather than instruction-level, which is exactly why
they survived the F6 fix below while F1 and F5 did not.

### What may not

| | Invariant | Status | The gap |
| :-- | :-- | :-- | :-- |
| **F1** | Reserve sufficiency | **design only** | **Vacuous, not enforced.** The ceiling lived in `compute_swap_grx_for_thbc`; the F6 fix removed that instruction and `PegBreach` now has **zero call sites**. `attested_reserve` is written by `update_attestation` and never read for a check. No program mints THBC at all, so supply cannot grow past anything — but "nothing can violate it because the operation does not exist" is not a guarantee. `issue_thbc` must re-attach the ceiling, as `attested_reserve − reserve_encumbered`. |
| **F2** | Issuance conservation | partial | **Detective, not preventive.** Nothing rejects a write for breaking `Σ issued − Σ redeemed = supply`; the reconciler reports drift after the fact. It currently reconciles against the simulated ledger, because `issue_thbc` and `redeem_thbc_for_fiat` do not exist. |
| **F3** | Deposit idempotency | **design only** | The `[b"deposit", H(bank_ref)]` nullifier PDA **does not exist**. The service enforces a `PRIMARY KEY` on the reference digest, which stops replays *through this service* and nothing else — not a second issuer path, not a manual transaction, not two deployments against two databases. The account-level guarantee needs the on-chain nullifier. **Do not report F3 as covered.** |
| **F4** | Burn-before-wire | partial | The ordering is enforced by the redemption state machine, which is the only route to a payout. But **there is no fiat rail behind it**, so the barrier has never been tested against a real payout queue. |
| **F5** | Attestation freshness | **design only** | **Unreachable, not enforced.** The freshness check lived on the minting swap and was removed with it — deliberately, since F5 guards *issuance* and the replacement `exchange_*` path issues nothing. `StaleAttestation` now has zero call sites. Must be re-attached to `issue_thbc`. F5 was claimable before 2026-07-29 and is not any more. |
| **F6** | Backing-set purity | partial *(code fixed)* | `swap_grx_for_thbc`/`redeem_thbc_for_grx` were replaced by `exchange_grx_for_thbc`/`exchange_thbc_for_grx`, which transfer against a `[b"thbc_inventory"]` vault. **No program mints or burns THBC any more.** Still not claimable, and the distinction is code vs *state*: THBC already minted by the old swap is still outstanding on any chain that ran it, and that supply is GRX-backed. Retiring or re-initialising it is what turns this Enforced. |
| **F7** | Redemption liveness | **design only** | The Δ-timelocked redemption escrow **does not exist on-chain**. Modelled in the service and the simulator only. See §6.4 below — the fiat side is unsolved even in design. |

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
- `issue_thbc` · `redeem_thbc_for_fiat` · `confirm_redemption` · `reclaim_redemption`
- Treasury fields `issuer`, `thbc_inventory`, `reserve_encumbered`, `redemption_queue_len`

In non-simulated mode the compliance port and the payout port **refuse** rather than
auto-pass, so these gaps fail loudly instead of looking like working integrations.

### Test coverage is partial, and here is how

Spec §13 asks for LiteSVM on F3, F5 and F7. What runs is `SimulatedLedger` — a model of
the treasury *as specified*. That demonstrates the service and the domain model are
correct; it demonstrates nothing about the chain, and for F3 and F7 the chain implements
nothing to demonstrate.

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
