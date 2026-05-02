# Markdown Files an LLM Coding Project Should Have

Here's the canonical set, organized by who reads them and when. Not every project needs every file — pick based on what your LLM (or human contributors) actually need to know.

## The Tier-1 Essentials (Every Project)

These four files do most of the work. If you only write four, write these.

**`README.md`** — root of repo. The human entry point. What this project is, how to run it, where to go next. Keep it tight; link out to the others. LLMs read this first to orient themselves.

**`ARCHITECTURE.md`** — root of repo. The single most valuable file for LLM-assisted development on a non-trivial codebase. One page is enough: a layer diagram, the crate/module inventory with one-sentence purposes, and the dependency-direction rule. Without this, an LLM has to reverse-engineer your structure from filenames every time. Rust-analyzer popularized the format; it's worth copying.

**`CLAUDE.md`** (or `AGENTS.md`, `.cursorrules`, `.github/copilot-instructions.md`) — root of repo. Instructions specifically for LLM coding assistants. What conventions to follow, what commands to run, what to avoid. Reth's `CLAUDE.md` is the reference example. The filename varies by tool; the content largely doesn't.

**`CONTRIBUTING.md`** — root of repo. How to set up the dev environment, run tests, format code, submit changes. LLMs use this to know what `cargo` commands matter, what the PR template expects, what the review bar is.

## Tier-2: Strongly Recommended for Serious Projects

**`CHANGELOG.md`** — what changed when. Helps both humans and LLMs understand recent evolution. Use Keep a Changelog format if you don't have a strong opinion.

**`SECURITY.md`** — how to report vulnerabilities, what's in scope, what versions are supported. GitHub surfaces this prominently.

**`CODE_OF_CONDUCT.md`** — community norms. Standard text from Contributor Covenant is fine.

**`LICENSE`** — not Markdown but mandatory. Apache-2.0 OR MIT is the Rust ecosystem default.

**`docs/glossary.md`** — domain terms with definitions. Critical for projects with specialized vocabulary (energy markets, blockchain, medical, legal). LLMs guess wrong on domain terms without this.

## Tier-3: Subsystem and Per-Crate Documentation

**`<crate>/README.md`** — one per workspace member. What this crate is, what it depends on, what depends on it. LLMs use these to decide where to add code.

**`docs/repo/layout.md`** — extended structure documentation when `ARCHITECTURE.md` isn't enough. Reth uses this pattern.

**`docs/design/<topic>.md`** — design documents for major subsystems. One file per subsystem. Explains the *why* that the code can't.

**`docs/adr/NNNN-<title>.md`** — Architecture Decision Records. Numbered, immutable, append-only. Each one captures a single decision: context, options considered, decision, consequences. The format is deliberately small. Critical for explaining "why didn't you do X?" months later — to humans and LLMs alike.

## Tier-4: LLM-Specific Files

This is the newer and more volatile category. Conventions are still settling.

**`CLAUDE.md`** — Claude Code reads this automatically. Project conventions, commands, gotchas.

**`AGENTS.md`** — emerging cross-tool convention for agent instructions. Some tools (Cursor, Aider, others) are converging on this name.

**`.cursorrules`** — Cursor-specific (technically not Markdown, but lives next to these).

**`.github/copilot-instructions.md`** — GitHub Copilot's repo-level instructions.

**`docs/llm/conventions.md`** — your own house style for LLM contributions. What patterns to prefer, what to avoid, how to format PR descriptions.

**`docs/llm/examples/`** — a folder of canonical example files showing the patterns you want LLMs to imitate. Often more effective than prose instructions.

**`SKILL.md` files** — for the Anthropic skill ecosystem. One per skill, in its own directory.

## Tier-5: Operational and Process Docs

**`docs/runbook.md`** or `docs/runbooks/<scenario>.md` — what to do when things break. Per-incident-type runbooks scale better than one giant file.

**`docs/deployment.md`** — how this gets to production.

**`docs/observability.md`** — what's logged, what's metered, how to debug.

**`docs/onboarding.md`** — first-week guide for new contributors. Often duplicates `CONTRIBUTING.md`; merge if so.

**`.github/PULL_REQUEST_TEMPLATE.md`** — what every PR description should contain.

**`.github/ISSUE_TEMPLATE/*.md`** — bug report template, feature request template, etc.

## Tier-6: Domain-Specific (Pick If Applicable)

**`docs/api/*.md`** — for projects with public APIs. Often auto-generated from OpenAPI/proto specs.

**`docs/protocol.md`** — wire format documentation for projects with custom protocols.

**`docs/threat-model.md`** — for security-sensitive projects.

**`docs/compliance.md`** — regulatory compliance notes. For GridTokenX: PDPA, ERC sandbox terms, Thai SEC requirements.

**`docs/data-model.md`** — database schemas, entity relationships, migration policy.

## A Recommended Set for GridTokenX

Given your project context (blockchain, hackathon, eventually production, mixed audience of judges and developers), here's what I'd actually create:

```
gridtokenx/
├── README.md                      # what this is, how to demo
├── ARCHITECTURE.md                # layer diagram, crate inventory
├── CLAUDE.md                      # LLM coding conventions
├── CONTRIBUTING.md                # dev setup, cargo commands
├── CHANGELOG.md
├── SECURITY.md
├── LICENSE                        # Apache-2.0 OR MIT
├── docs/
│   ├── glossary.md                # GRID, GRX, REC, VPP, LOLE, etc.
│   ├── design/
│   │   ├── tokenomics.md          # GRID + GRX, USD anchor model
│   │   ├── matching-engine.md     # CDA design, invariants
│   │   ├── oracle-bridge.md       # IoT → chain integrity story
│   │   ├── settlement.md          # atomic settlement protocol
│   │   └── rec-issuance.md        # ERC-1155 model
│   ├── adr/
│   │   ├── 0001-solana-over-evm.md
│   │   ├── 0002-erc1155-for-recs.md
│   │   ├── 0003-switchboard-oracle.md
│   │   └── 0004-grx-deflationary.md
│   ├── compliance/
│   │   ├── pdpa.md
│   │   ├── erc-sandbox.md
│   │   └── thai-sec-group1.md
│   ├── deployment.md
│   ├── runbook.md
│   └── llm/
│       ├── conventions.md         # Rust style for this project
│       └── examples/              # canonical files to imitate
└── crates/<each>/README.md        # one per crate
```

That's roughly 25 files at the start, most of them short. The high-leverage ones to write first: `ARCHITECTURE.md`, `CLAUDE.md`, `docs/glossary.md`, and the first few ADRs. Everything else can grow as needed.

## Practical Tips for LLM-Friendly Markdown

A few patterns that make these files actually useful to LLMs:

- **Front-load the structure.** Tables of contents, clear headers, predictable section names. LLMs scan for sections; help them find what they need.
- **Use definition lists or tables for vocabulary.** Easier for an LLM to parse than prose paragraphs of "X means Y, while Z is...".
- **Link aggressively between docs.** When `ARCHITECTURE.md` mentions the matching engine, link to `docs/design/matching-engine.md`. LLMs follow these links when given filesystem access.
- **Include `Last reviewed: YYYY-MM-DD` in design docs.** Tells both humans and LLMs how stale to assume the content is.
- **Keep `CLAUDE.md` updated as you discover patterns.** It's a living file, not a one-time setup.
- **Don't hide knowledge in commit messages.** If a decision is important, it goes in an ADR. Commit messages get lost.
- **Use code blocks with language tags everywhere.** ` ```rust ` not just ` ``` `. LLMs (and syntax highlighters) use the tag.

## What to Skip

A few things that show up in templates but aren't worth the effort for most projects:

- **`AUTHORS.md`** — git history is the source of truth
- **`HISTORY.md`** — same as `CHANGELOG.md`, pick one
- **Massive single-file docs over ~1000 lines** — split them; both humans and LLMs handle multiple focused files better than one giant one
- **Auto-generated table-of-contents Markdown** — most renderers and LLMs handle headers fine without one

Want me to draft any of these for GridTokenX? `ARCHITECTURE.md` and `CLAUDE.md` would be the highest-leverage starting points — both are short, both pay off immediately, and both establish patterns the rest of the docs follow.