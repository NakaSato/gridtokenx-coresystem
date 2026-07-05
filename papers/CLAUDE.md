# papers/ — Research Reference ONLY

This folder is **research material, not implementation**.

- Fetched papers (markdown), extracted equations/tables, and prototype/sketch code
  written to understand a paper.
- **Never implement from here into a `gridtokenx-*` service.** Prototypes are
  illustrative, not production. No copying into service workspaces, no `cargo add`,
  no wiring — unless the user explicitly opens a separate task to do so.
- **Not in any Cargo workspace.** Test prototypes standalone (`rustc --test`) only.
- Prototypes may skip error handling / use `.unwrap()` / ignore architecture rules.

See root [CLAUDE.md](../CLAUDE.md#research-reference-papers) for the full rule.
