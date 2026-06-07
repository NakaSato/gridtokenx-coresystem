# Active Execution Plans

One file per in-flight plan. A plan here is a concrete, scoped sequence of work with a definition
of done — not a vague idea (those live in [`../../PLANS.md`](../../PLANS.md)).

## File convention

- Filename: `NNNN-short-slug.md` (e.g. `0001-settlement-outbox-atomicity.md`).
- Each plan states: goal, affected services, ordered steps, done criteria, owner.
- When complete, move the file to [`../completed/`](../completed/) and tick the done criteria.

## Existing large plans (not yet migrated here)

- [`../E2E_IMPL_PLAN.md`](../E2E_IMPL_PLAN.md) — end-to-end implementation plan
- [`../E2E_TEST_PLAN.md`](../E2E_TEST_PLAN.md) — end-to-end test plan
