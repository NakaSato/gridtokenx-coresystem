# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single **academic paper** written in [Typst](https://typst.app) — not a code project. It is a Thai-language IEEE-conference-style article on a Peer-to-Peer solar energy trading system (Solana consortium blockchain, CDA matching, PoA consensus, microservices). It documents the `gridtokenx-coresystem` superproject that lives in the parent directory, but builds and versions independently. Requires `typst` ≥ 0.13 (developed on 0.15.0).

## Build

Fonts are vendored in `font/` (not installed system-wide), so **every invocation must pass `--font-path font/`** or Thai/Times glyphs fall back and the layout breaks.

```bash
# One-shot PDF
typst compile main.typ --font-path font/ main.pdf

# Live preview while editing (recompiles on save)
typst watch main.typ --font-path font/ main.pdf

# After editing: confirm it still compiles cleanly (the only "test" here)
typst compile main.typ --font-path font/ /tmp/check.pdf
```

There is no build script or `justfile` — drive `typst` directly.

## Structure

- `main.typ` — entry point. Sets paper metadata (title/authors/abstract/keywords in the `ieee-conf` show rule) and `#include`s each section **in reading order**. Adding a section = create `sections/<name>.typ` + add an `#include` line here. The bibliography is rendered last from `references.bib`.
- `ieee-template.typ` — the `ieee-conf` layout function (page geometry, two-column body, heading numbering `I.A.1.`, figure/table/equation styling, title block). All visual formatting lives here; section files contain only content. Edit this to change look, not the sections.
- `sections/*.typ` — content body, one file per paper section (`introduction`, `related-work`, `settlement-model-invariants`, `system-design`, `evaluation`, `discussion_limitations`, `conclusion`).
- `references.bib` — BibTeX, rendered IEEE style.
- `font/` — vendored TTFs: **TH Sarabun New** (Thai body), Times New Roman (English body/headings), Courier (code). Referenced by family name in the template's `set text(font: ...)`.
- `picture/` — figures (PNG) pulled in via `#figure(image(...))`.
- `backup.txt` — loose prose drafts (abstract variants etc.), not compiled.

## Conventions specific to this paper

- **Bilingual Thai/English.** Body text is Thai; technical terms keep their English name, usually as `ไทย (English)` on first use. Match this when adding prose.
- **Justification is off inside narrow columns by design** — Thai has no inter-word spaces and over-stretches. Don't re-enable `justify` in headings/title; it's deliberately scoped off there (see template comments).
- **Headings are auto-numbered** (`I.`, `A.`, `1)`). Use plain Typst headings (`=`, `==`, `===`); never hand-number them. "References"/"REFERENCES"/"เอกสารอ้างอิง" are special-cased to render unnumbered.
- Reference figures/tables/equations with Typst labels and `@ref`, not hardcoded numbers — numbering is automatic.
