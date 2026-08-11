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
| 3.1. Equations and Data | 3.1. Measured Outcomes and Limitations |
| — (new) | 3.2. Where the Prosumer's Revenue Goes |

The dataset that Section 3.1 used to hold is now introduced in the Section 3
preamble, next to the definitions of the metrics it feeds, so no subsection exists
whose title promises content it does not carry.

### R1.2 — "In Section 3.1, 'Equations and Data,' there are no equations presented in this subsection."

Correct on both counts, and we have fixed the cause rather than only the title.
The dataset table that occupied the subsection has moved into the Section 3
preamble, and the two subsections that remain (3.1 *Measured Outcomes and
Limitations*, 3.2 *Where the Prosumer's Revenue Goes*) are each named for what
they contain.

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
3. **Sections 3.1 and 3.2** carry the findings themselves, supported by two new
   tables: **Table 2** gives each measurement alongside *what it bounds*, and
   **Table 3** decomposes prosumer revenue into gross, fee, wheeling, loss and net.

The three findings are now counted as one set throughout, which they previously
were not: the abstract announced a singular "main finding", Section 3.1 said "two
findings follow", and Section 3.2 then referred to "the third finding". The
abstract now reads "Three findings follow", marks the first as primary, and the
two subsections continue that count. We are grateful for the observation that this
mismatch was itself a source of the confusion.

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
  ledger, sets the P2P participation threshold. **Table 3** now shows the
  deduction that drives it: wheeling takes 1,278 THB from each P2P rule, a third of
  the uniform auction's gross, and nothing at all from the buy-back, while fees and
  the loss allowance together account for about 0.3%.
- **We corrected a claim that had overstated our headroom.** The manuscript
  measured settlement against "the 1.4 M CU ceiling", which is the maximum a Solana
  transaction may *request*, not the budget it is granted. Against the 200 k
  default a match uses about half, and compute was never the binding constraint at
  all: the 1,232-byte packet is, because each match carries its 77-byte signed
  order twice, once in the Ed25519 verification instruction and once as settlement
  instruction data. Section 3.1 and Table 2 now say this.

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

The revision also adds a second contribution of the same kind, which we had
measured but not stated: settlement on this design is bound by transaction packet
size rather than by compute, and Address Lookup Tables cannot relieve it, because
they compress account keys while the cost here sits in instruction data. The
consequence — that denser settlement requires repackaging signatures, not
requesting more compute — is a design constraint that transfers to any
signature-verifying settlement layer, and we have not seen it reported in the P2P
energy-trading literature.

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
- Added Table 3 and a subsection decomposing prosumer revenue, so the economic
  finding is demonstrated rather than asserted.
- Restyled all three tables to booktabs form (horizontal rules only), which reads
  more cleanly and recovered most of the space the new table needed.
- Fixed silent font fallback: the vendored Times New Roman has no baht glyph
  (U+0E3F is absent from its cmap), so every "฿" was being set in Rockwell,
  including in a bold table header. Amounts are now written THB. Two Table 1
  entries that had been set in math mode, and so rendered in a maths face rather
  than Times, are now Times text.
- The paper remains within the two-page limit.
