# Quality Score

A shared rubric for "is this change good enough to merge." Score is a guide for reviewers and a
checklist for authors — not a gate that overrides judgment.

## Dimensions

| Dimension | What it asks | Weight |
| :--- | :--- | :--- |
| Correctness | Does it do what the spec says, including edge cases? | ★★★ |
| Safety of value | Are balances/settlement/minting paths idempotent and replay-safe? | ★★★ |
| Architecture fit | Respects dependency direction & sync-core/async-edges? | ★★ |
| Error handling | No `.unwrap()` in prod paths; `Result` with context? | ★★ |
| Observability | `#[instrument]` on public async fns; secrets skipped? | ★★ |
| Tests | Unit for core logic; integration/e2e for cross-service flows? | ★★ |
| Security | No leaked secrets; chain access only via Chain Bridge? | ★★★ |
| Clarity | Reads like surrounding code; naming/idioms consistent? | ★ |

## Scoring

- **Ship** — all ★★★ dimensions pass, no ★★ regressions.
- **Revise** — a ★★ gap or a missing test on a value path.
- **Block** — any ★★★ failure: wrong settlement, leaked secret, direct Solana RPC, reversed deps.

## Author Checklist (pre-PR)

- [ ] `cargo check` / `cargo test` green in each touched service workspace
- [ ] `cargo clippy -- -D warnings` clean
- [ ] `cargo sqlx prepare` run if queries changed
- [ ] No new `.unwrap()` in production paths
- [ ] No secrets in logs; `skip` applied where needed
- [ ] Submodule pointer + inner code committed correctly
- [ ] Relevant spec / design doc updated

See enforced conventions in [`../CLAUDE.md`](../CLAUDE.md).
