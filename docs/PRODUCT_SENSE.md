# Product Sense

The lens for judging whether a change is *right for the user*, not merely correct. Use this when a
decision is underspecified by the spec and you must fill the gap with judgment.

## Who We Serve

- **Prosumers** — produce energy (solar, etc.) and want to sell surplus fairly and get paid reliably.
- **Consumers** — want cheaper, traceable energy and trust that what they buy is real.
- **Grid operators / regulators** — need auditable, non-repudiable records and grid stability.

The unifying promise: **trustless, verifiable energy trading**. Every feature is judged against
whether it strengthens or erodes that trust.

## Heuristics

1. **Trust beats convenience.** When a shortcut would weaken verifiability or auditability, don't
   take it. A slower, provable flow wins over a fast, hand-wavy one.
2. **The physical and the financial must agree.** A trade that doesn't correspond to real, attested
   energy is a bug regardless of how clean the code is.
3. **Money flows must be boringly correct.** Settlement, balances, and minting tolerate zero
   ambiguity. Prefer explicit, idempotent, replayable over clever.
4. **Degrade honestly.** If telemetry is missing or the chain is unreachable, surface it — never
   paper over it with a plausible default.
5. **Custody is a promise.** Custodial wallets mean we hold users' keys; that bar is sacred — never
   log, leak, or weaken key handling for expedience.

## Anti-Patterns

- Optimizing latency by skipping signature verification.
- "Eventually consistent" treated as "probably fine" for value.
- UI that implies finality before on-chain settlement confirms.
