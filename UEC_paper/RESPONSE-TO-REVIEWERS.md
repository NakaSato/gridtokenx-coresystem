# Response to Reviewers

**Paper:** Implementation of Peer-to-Peer Energy Trading via Solana Smart Contracts
in a Permissioned Environment
**Authors:** Chanthawat Kiriyadee, Suwannee Adsavakulchai (University of the Thai
Chamber of Commerce)

We thank both reviewers for their time and for comments that were specific enough
to act on directly. Every point below has been addressed in the revised two-page
manuscript. Section and table numbers refer to the revised version.

---

## Reviewer 1

### R1.1 — "The names of each section should be revised to accurately reflect its content. It is not necessary to use the same section titles as those in the template."

Agreed; the template titles had been carried over unchanged. All section titles are
now specific to their content:

| Original | Revised |
| --- | --- |
| 1. Introduction | 1. Motivation and Design Rationale |
| 2. Methodology | 2. On-Chain Settlement Layer and Simulated Grid |
| 3. Key Results and Discussion | 3. Throughput, Audit, and Revenue Results |
| 3.1. Equations and Data | 3.1. Simulated Community-Month Dataset |
| — (new) | 3.2. Measured Outcomes and Limitations |

### R1.2 — "In Section 3.1, 'Equations and Data,' there are no equations presented in this subsection."

Correct on both counts, and we have fixed the cause rather than only the title.
Section 3.1 is now *Simulated Community-Month Dataset*, which is what the
subsection actually contains (Table 1).

Separately, the reviewer's observation exposed a real omission: the closure
identities that the audit harness checks had been dropped from this short version
of the paper while the sentence referring to them was left behind, which is why the
manuscript read "The closure identities of hold exactly on chain." The three
identities are now stated explicitly as Eq. (1) in Section 2 — energy minted =
settled = burned, REC supply, and currency conservation `Σ Tₘ = P_sell + W` — with
all symbols defined and the fourteen chain-derived audit assertions described. The results section
now refers to Eq. (1) by number.

### R1.3 — "The Acknowledgement and References sections should not be assigned section numbers."

Fixed, and the underlying defect is worth recording. Both headings were already
declared unnumbered in the source; the template's level-1 heading rule printed the
heading counter unconditionally, so it ignored `numbering: none` and both headings
inherited the preceding section's number. The rule now emits a number only for
headings that carry one. Acknowledgment, References, and Conclusion all render
without numbers.

---

## Reviewer 2

### R2.1 — "'4. Acknowledgment' and '4. References' are wrong."

Confirmed and fixed; see R1.3 above for the cause.

### R2.2 — "The paper is unclear. It is unclear what the finding is."

This was fair, and it drove the largest revision. The findings were previously
buried in a single dense paragraph of run-on measurements. The revision states them
in three places, at increasing detail:

1. **Abstract** now ends with an explicit finding sentence: the execution layer is
   not the binding constraint (the community-month replays 1,858× faster than real
   time with zero delivery loss, and all fourteen chain-derived conservation assertions close
   exactly against on-chain state), and participation is instead decided by the
   price rule.
2. **Section 1** states up front the design claim the paper tests: with hot-path
   state partitioned per entity, what remains of the scaling limit is consensus and
   lock serialization, not on-chain computation.
3. **Section 3.2** presents three enumerated findings, supported by the new
   **Table 2**, which gives each measurement alongside *what it bounds*
   (throughput, compute headroom, delivery loss, audit exactness, revenue).

### R2.3 — Reliability (scored 1)

We have made the evidence checkable rather than asserted:

- **Eq. (1)** states precisely what the audit assertions verify, and
  Section 2 lists what the harness re-derives from live chain state by RPC reads
  alone (per-meter counters, PDA censuses, registry conservation sums, token
  supplies and balances).
- **Table 2** ties every headline number to the claim it supports.
- A **limitations paragraph** has been added, stating plainly that (i) goodput on a
  single validator bounds execution and account locking only and is *not* a
  consensus-throughput result for a three-utility consortium; (ii) the telemetry
  outcome reproduced bit-identically across four runs with throughput varying
  213–232 readings·s⁻¹ under host load, while the lifecycle figures come from one
  canonical run and the price-rule comparison from a separate sweep, because
  per-order and per-trade nullifier PDAs make an identical replay impossible on a
  persistent ledger; and (iii) the dataset is simulator-produced, with no field
  measurements.
- The revenue ranking is now **qualified rather than absolute**: it holds while
  prosumer supply is capped near demand, and reverses when supply is left uncapped,
  because the regulated buy-back bears no wheeling charge. This strengthens rather
  than weakens the underlying claim, which is that the wheeling charge, not the
  ledger, sets the P2P participation threshold.

### R2.4 / R1 — Originality (scored 2 by both reviewers)

We accept this as the weakest axis and have sharpened the contribution claim rather
than overstate it. Section 1 now positions the work against the existing P2P and
blockchain-energy literature (three references added: Sousa *et al.* 2019, Andoni
*et al.* 2019, and the Brooklyn Microgrid study of Mengelkamp *et al.* 2018) and
states what is different here: that body of work reports throughput and market
outcome, but seldom evidence that the ledger conserves energy and currency exactly.
This paper supplies that evidence, as an exactly audited closure over a full token
life-cycle, together with a revenue comparison against Thailand's actual regulated
buy-back rate.

We note candidly that a same-workload comparison against the Tendermint stack used
by NETP would be the strongest possible support for the "alternative execution
layer" framing. That requires a further experiment rather than a revision, and we
would be glad to include it in an extended version.

---

## Other changes made in this revision

- Corrected an internal inconsistency: the program count read "five core programs"
  while six were named (and the abstract said six). It is six.
- Replaced the abstract's placeholder "$M$ meters over $D$ days" with the actual
  configuration (80 meters, 30 days).
- Corrected several grammatical errors, including "However, remains in
  development," "This article present," "compiled" for "complied," "The contribution
  of this work are," and "The outcomes replays."
- Added a corresponding-author footnote and separated the two contact addresses,
  which previously rendered as a single mailto link containing both.
- Repaired the title, which was missing two words: "…via Solana Smart Contracts
  **in a** Permissioned Environment."
- Normalised spelling to one convention throughout (*realized*, *modeled*,
  *summarizes*, alongside *serialization*), which had been mixed.
- **Corrected the audit count from fifteen to fourteen.** On re-auditing our own
  harness for this revision we found that one of its fifteen checks compares a
  constant with itself and therefore reads nothing from the chain. Fourteen
  assertions are genuine RPC reads against live chain state. Every reported
  conservation result is unchanged; only the count is corrected. We prefer to
  report the smaller, defensible number.
- The paper remains within the two-page limit.
