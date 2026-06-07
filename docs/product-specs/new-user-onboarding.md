# Product Spec: New User Onboarding

**User:** A prosumer or consumer signing up for the first time.
**Goal:** Get from "no account" to "able to trade energy" with a funded, on-chain-registered wallet.

## Happy Path

1. User registers with email + password via the trading UI (through APISIX `:4001`).
2. IAM Service creates the account and provisions an **encrypted custodial wallet**
   (AES-256-GCM, key derived from `ENCRYPTION_SECRET`).
3. IAM submits **on-chain registration** — a Registry program PDA mapping wallet → node identity
   (via Chain Bridge; idempotent).
4. User lands on a dashboard showing wallet address, zero balances, and an empty order book view.
5. User can now place a first order, which routes to the Trading Service CDA engine.

## Edge Cases

| Case | Expected behavior |
| :--- | :--- |
| Email already registered | Reject with structured error; no wallet created |
| Solana validator unavailable at step 3 | Account usable; registration retried — idempotent, no duplicate PDA |
| `ENCRYPTION_SECRET` < 32 chars | Startup fails fast; account creation never proceeds |
| Duplicate on-chain registration | No-op; existing PDA returned |

## Acceptance Criteria

- [ ] A new email yields exactly one account and one encrypted wallet.
- [ ] Wallet private key is never returned to the client and never logged.
- [ ] On-chain registration is idempotent — replaying step 3 creates no second PDA.
- [ ] A user who completes onboarding can place a valid order without further setup.
- [ ] Registration survives a transient validator outage without manual intervention.

## Traceability

- Implementation: IAM Service (`gridtokenx-iam-service/`), see its `ARCHITECTURE.md`.
- Tests: `tests/e2e/` registration + minting phases.
