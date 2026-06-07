# Tech Debt Tracker

Running ledger of known shortcuts, deferred work, and architectural debt. Each item has an owner-
intent, a blast radius, and a trigger that says when it must be paid down.

Status legend: 🔴 blocking · 🟠 should-fix · 🟢 nice-to-have · ✅ paid down

| ID | Item | Area | Severity | Trigger to pay down | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| TD-001 | _example_ — direct DB call bypassing repository layer | trading | 🟠 | before next settlement refactor | open |

## How to use

1. Add a row when you knowingly take a shortcut. Reference the commit or PR that introduced it.
2. Severity reflects risk if left unpaid, not effort to fix.
3. The **trigger** is the condition that converts the debt from "tolerated" to "must fix now" —
   usually a feature that would compound it.
4. Move resolved items to ✅ with the paying commit; keep them for one quarter, then prune.

## Sources to mine for debt

- [`../../gridtokenx-refactor-checklist.md`](../../gridtokenx-refactor-checklist.md)
- [`../../gridtokenx-refactor-plan.md`](../../gridtokenx-refactor-plan.md)
- `cargo clippy -- -D warnings` output across services
- `// TODO` / `// FIXME` / `// HACK` markers in service code
