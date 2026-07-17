# Plans

The roadmap layer: directions and intentions that are not yet scoped into concrete execution
plans. When an item here becomes actionable, it graduates to a file in
[`exec-plans/active/`](exec-plans/active/) with ordered steps and done criteria.

## Hierarchy

```
PLANS.md (this file)        → directions, themes, "we should eventually…"
   └─ exec-plans/active/    → scoped, ordered, has a definition of done
        └─ exec-plans/completed/  → archived with retro
```

## Themes

| Theme | Intent | Status |
| :--- | :--- | :--- |
| DB-per-service split | Isolate each service's schema into its own database. Noti already isolated; Phase 1 (Trading → `gridtokenx_trading`) live and e2e-validated; Phase 2 (Metering → `gridtokenx_meter`) rolled back — meter-service still JOINs `users`; Phase 3 (Chain) authored, not cut over. See [`design-docs/db-per-service-migration.md`](design-docs/db-per-service-migration.md) §5d. | in progress |

_Keep themes coarse; detail belongs in exec-plans._

## Tracking

- Active scoped work: [`exec-plans/active/`](exec-plans/active/)
- Known debt that constrains plans: [`exec-plans/tech-debt-tracker.md`](exec-plans/tech-debt-tracker.md)
- Large existing plans: [`exec-plans/E2E_IMPL_PLAN.md`](exec-plans/E2E_IMPL_PLAN.md), [`exec-plans/E2E_TEST_PLAN.md`](exec-plans/E2E_TEST_PLAN.md)
