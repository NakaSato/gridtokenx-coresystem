# Research statement — verifiable physical measurement without a trusted custodian

## 1. The open problem

A settlement system that pays for a physical quantity must convert a measurement
into a claim that a third party will honour. The measurement originates at a
device the payer does not control, and the claim is consumed by a ledger the
device does not control. Every deployed design I am aware of closes this gap by
introducing a custodian — an aggregator that attests the reading, and a signer
that commits it — and then asserts that the custodian is honest. However much
machinery surrounds them, the trust graph collapses to two unconditionally
trusted nodes, and the guarantee offered to the consumer of the claim is
therefore *institutional*, not cryptographic. The open problem I want to work on
is whether that guarantee can be made cryptographic: can a measurement carry, to
a party that trusts neither the device nor the aggregator, evidence that it was
produced by an attested sensor, aggregated without omission or reordering, and
committed exactly once — with correction of an erroneous commitment remaining
possible but publicly accountable? The last clause is what makes it hard. A
scheme that only prevents rewriting cannot express a late or corrected reading,
and a scheme that permits rewriting reintroduces the custodian it was meant to
remove.

## 2. Why this laboratory

Two lines of the laboratory's work bear directly on the two halves of that
problem, and I would build on both.

**The M+1st-price auction line** — *Bidder Scalable M+1st-Price Auction with
Public Verifiability* (TrustCom 2021), *Scalable M+1st-Price Auction with
Infinite Bidding Price* (SciSec 2022), and *Blockchain Based M+1st-Price Auction
With Exponential Bid Upper Bound* (IEEE Access 11, 2023) — establishes a
sealed-bid mechanism whose outcome is publicly verifiable **without a trusted
manager**. The clearing layer I have built is a continuous double auction whose
matching engine is exactly the trusted manager this line eliminates: it observes
every order before clearing, and participants have no means to verify that the
published outcome follows from the submitted orders. The concrete primitive I
would build on is the public-verifiability construction of the M+1st-price
protocol, and the concrete question is what is lost when the mechanism must clear
continuously rather than in sealed rounds — whether verifiability survives the
move from a batch auction to a continuous one, or whether the correct answer is
that a physical-settlement market should be a repeated sealed-bid auction and my
current design is simply wrong.

**Revocable Policy-Based Chameleon Hash for Blockchain Rewriting** (Tian, Miyaji,
Matsubara, Cui and Li, *The Computer Journal* 66(10), 2023) addresses the second
half. My audit layer is at present an ordinary hash chain, which is tamper-
evident and therefore cannot express a correction at all; my open defect (§4)
is precisely a reading that arrives after its settlement window has closed and
has nowhere to go. A policy-based chameleon hash with revocation is the primitive
that makes a *lawful, attributable* correction expressible — the rewriting
privilege is bound to a policy and can be withdrawn — and I would like to
understand whether a correction path built on it can be made to preserve a
conservation invariant over the corrected series, which is the property a
settlement ledger actually needs and which rewriting naively destroys.

## 3. Evidence that I can execute independently

I have built and operate the system described here — ten Rust services, on-chain
programs, and a sixteen-suite end-to-end harness that brings up the full stack
and runs cross-service flows against it (repository and run artifacts available).
Four settlement invariants — idempotency, monotonicity, conservation and
curtailment-safety — are specified and exercised against simulation on the
CINELDI reference feeder.

## 4. What I already know is wrong with it

I would rather present the defects than the green numbers, because the defects
are what define the research.

**A known unresolved correctness defect (TD-002).** Settlement mints a window
once, keyed by a derived address over `(meter, window)`. A reading whose
timestamp falls inside an already-settled window re-creates the window, but the
mint is a no-op, so that energy is silently **under-**credited. This is the
inverse of a double-spend and the address key is what prevents the double-mint,
so the guard is doing its job; the failure is that the design has no notion of a
correction. I have landed a grace period, which closes only the boundary case: a
reading arriving shortly after a window closes now lands before settlement. A
genuinely late replay — an offline-buffered meter reconnecting hours later —
still strands its energy. This is the defect that motivates §2's second half.

**Invariant coverage is partial.** Idempotency and conservation are exercised
directly. Monotonicity and curtailment-safety are demonstrated only in
simulation, and curtailment-safety is in any case a weaker statement than it
sounds: it says the ledger correctly *records* a curtailment that occurred, not
that the system can cause or prevent one.

**I have no measured throughput ceiling, and one of my stated ceilings does not
exist.** I would rather present this than be asked about it. My benchmark report
sweeps transaction concurrency from 5 to 40 and finds throughput climbing
monotonically — 9.4× over an 8× increase in load — with no plateau. Its own
conclusion is that the single node does not saturate over the swept range, and it
instructs the reader, in as many words, not to cite a saturation knee and not to
quote a maximum sustainable rate until concurrency has been pushed past 40 to
locate peak or collapse. That instruction exists because an earlier run *did*
report a knee and that headline had to be retracted when it failed to reproduce.

Against that, I have elsewhere written that single-signer mint issuance holds at
≈5.33 mints per second, attributed to a shared write-lock and claimed to be
independent of device count. Checking it, none of that survives. The figure is
not in the benchmark report it is cited to — that report measures the mint path's
*compute cost per instruction*, never its rate. The number is instead an ingest
offered load: eighty meters divided by a fifteen-second reporting cadence is
exactly 5.33 readings per second. So it is an arrival rate on one subsystem
presented as a capacity ceiling on another, and the "independent of device count"
claim is contradicted by its own derivation, since doubling the meters doubles
it. The write-lock hypothesis may still be true — it is a reasonable thing to
suspect of a shared account — but nothing I have measured tests it, and the same
report records sustained ingest two orders of magnitude above the supposed
ceiling. I have removed the claim from my architecture notes and am treating it
as an open question rather than a result. The experiment that would settle it is
not difficult: drive open-loop offered load past the suspected knee against one
signer and against *n*, and report whether the knee moves with *n*. I have not
run it, and until I do I have a hypothesis, not a bottleneck.

## 5. Plan

**Months 1–6 — one checkable deliverable.** A formal statement of the
measurement-to-claim problem as a security game, with an explicit adversary who
controls the aggregator, together with the saturation experiment described above.
The deliverable is checkable in the strict sense: the game either admits the
two-custodian design as secure (in which case my framing is wrong and I will say
so) or it does not, and the experiment either moves the knee with signer count or
it does not. Both outcomes are publishable and both are falsifiable by someone
who does not trust me.

**Months 7–12.** Construct a commitment scheme for aggregated measurement that is
verifiable to a consumer trusting neither device nor aggregator, and identify
what device-side assumption is irreducible — I expect something attestation-like
survives, and I want to know its exact shape rather than assume it away.

**Months 13–18.** Attack the correction problem: a policy-bound, revocable
rewriting path for committed measurement that preserves conservation over the
corrected series. This is TD-002 stated properly.

**Months 19–24.** Composition and evaluation: whether the clearing mechanism of
§2 and the measurement commitment above compose without either's verifiability
being lost, and a written account of what the resulting trust graph actually is —
which is the question I started from.

---

### Sources for the citations above

All four verified against publisher records (July 2026).

- Hsu & Miyaji, *Bidder Scalable M+1st-Price Auction with Public Verifiability*,
  TrustCom 2021, pp. 34–42, IEEE — https://ieeexplore.ieee.org/abstract/document/9724495/
  Removes the trusted manager **and** the trusted mix servers; a winning bidder
  proves their own win. This is the property §2 relies on.
- Hsu & Miyaji, *Scalable M+1st-Price Auction with Infinite Bidding Price*,
  SciSec 2022, LNCS — https://link.springer.com/chapter/10.1007/978-3-031-17551-0_8
- Hsu & Miyaji, *Blockchain Based M+1st-Price Auction With Exponential Bid Upper
  Bound*, IEEE Access 11:91184–91195 (2023) — https://ieeexplore.ieee.org/document/10225494/
  Binary bidding vector lifts the bid upper bound to 2^n; also manager-free.
- Tian, Miyaji, Matsubara, Cui & Li, *Revocable Policy-Based Chameleon Hash for
  Blockchain Rewriting*, The Computer Journal 66(10):2365–2378 (2023) —
  https://academic.oup.com/comjnl/article-abstract/66/10/2365/6627275

Laboratory publication list: https://cy2sec.comm.eng.osaka-u.ac.jp/miyaji-lab/activity/paper.html

**Not** by this laboratory, despite matching the topic almost exactly — do not
cite it as theirs: Al-Sada, Lasla & Abdallah, *Secure Scalable Blockchain for
Sealed-Bid Auction in Energy Trading*, IEEE ICBC 2021.
