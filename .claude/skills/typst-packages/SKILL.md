---
name: Typst Packages
description: Discover, evaluate, and wire Typst Universe packages (https://typst.app/universe) into the Paper/ academic paper. Use when the user wants a Typst package for a paper need (plots, diagrams, tables, glossary, equations, captions, theorems, citation/bib tooling), says "find a typst package for X", "add <package>", "what package does Y", "create a chart/diagram/table in the paper", or asks to browse Typst Universe. Knows the paper's vendored-font + open-PDF build rules and pins package versions.
---

## Typst Packages

Helps add the **right Typst Universe package** to the paper in `Paper/` (Typst,
Thai-language IEEE conference style — see `Paper/CLAUDE.md`). Universe is the
official registry: <https://typst.app/universe/search/?kind=packages>.

Goal: pick a maintained package, pin its version, wire the import, and confirm it
compiles — without breaking the vendored-font or two-column layout.

---

### Build rules this skill MUST respect (from `Paper/CLAUDE.md`)

- **Always** pass `--font-path font/` — Thai/Times glyphs are vendored, not system-wide.
- **First compile after adding a package needs network** — Typst downloads from
  Universe, then caches under `~/Library/Caches/typst/packages/preview/`.
- **Every successful compile → rebuild `main.pdf` and open it:**
  `typst compile main.typ --font-path font/ main.pdf && open main.pdf`
- Run from inside `Paper/`. The compile is the only "test"; a clean exit = pass.

---

### Workflow

1. **Clarify the need** in one line (plot? diagram? table? glossary? theorem? units?).
   Match it to the curated list below before searching the web.
2. **Find / confirm the package**:
   - WebFetch `https://typst.app/universe/search/?kind=packages&q=<keyword>` or the
     package page `https://typst.app/universe/package/<name>` for the current version
     + import line + minimal example.
   - Or read the already-cached source for an installed package:
     `~/Library/Caches/typst/packages/preview/<name>/<version>/src/` — grep the
     exported symbols and parameter names (do this to verify an API before writing,
     like the dual-axis `lq.axis` check done for lilaq).
3. **Pin the version.** Import with an explicit version: `#import "@preview/<name>:X.Y.Z"`.
   Never import without a version — unpinned breaks reproducibility. Use the latest
   stable shown on Universe unless the user asks otherwise.
4. **Wire it** in the section file (`sections/*.typ`) where used, or in `main.typ`
   if global (like `equate`). Keep imports at the top of the file.
5. **Compile + open** with the command above. If the first compile fails to fetch,
   report it (offline) — don't silently fall back.
6. **Mind the template**: figures/tables/equations get sizing from `ieee-template.typ`
   (captions 9pt, table body 7pt, equations 10pt). Wrap raw package output in
   `text(size: ...)` if it ignores the template, and keep figures within the ~7.7cm
   single-column width (or `scope: "parent"` for full-width floats).

---

### Already in this paper

| Package | Version | Where | Use |
| --- | --- | --- | --- |
| `fletcher` | 0.5.8 | `sections/system-design.typ` | node/edge diagrams (architecture, swimlanes, consensus) |
| `lilaq` | 0.6.0 | `sections/evaluation-bench.typ` | data plots (throughput/loss, dual-axis via `lq.axis`) |
| `equate` | 0.3.3 | `main.typ` | per-line equation numbering, sub-numbering `(1.1)` |

Reuse these before adding a new package for the same job.

---

### Curated packages for academic papers

Pick from here first; only web-search if nothing fits. Versions drift — confirm the
current one on Universe before pinning.

**Diagrams & figures**
- `cetz` — general vector drawing / TikZ-like (when fletcher's node-graph model is too rigid).
- `fletcher` — node-and-arrow diagrams, flowcharts, state machines (already used).
- `subpar` — sub-figures `(a) (b)` with shared numbering.

**Plots & charts**
- `lilaq` — modern data plots, error bars, twin axes (already used).
- `cetz-plot` — plotting built on cetz (alternative to lilaq).

**Tables**
- `tablem` / `tablex` — Markdown-ish or extended tables (merged cells, spans) when
  native `table` gets verbose. Native `table` + the template styling usually suffices.
- `zero` — number/unit-aware column alignment (decimal-aligned figures in tables).

**Equations & units**
- `equate` — multi-line numbering (already used).
- `physica` — physics/math shorthands (vectors, derivatives, brackets).
- `unify` / `zero` — typeset numbers with units/uncertainty (`5.33 plus.minus 0.1 "readings/s"`).

**Front/back matter**
- `glossarium` — glossary / acronyms with back-references (formalize the Abbreviations table).
- `wordometer` — live word/character count while drafting.
- `drafting` — margin notes / TODO callouts during review (strip before final).

**Theorems / boxes**
- `ctheorems` or `great-theorems` — numbered theorem/definition/lemma environments
  (useful for the invariants/settlement-model section).
- `showybox` — colored callout boxes.

**Bibliography**
- Native `#bibliography(..., style: "ieee")` is already used. For CSL styles not
  bundled, drop a `.csl` file and pass its path as `style:`.

---

### Guardrails

- **One package per real need.** Don't add a dep the native API already covers
  (native `table`, `figure`, `bibliography`, `math.equation` handle most cases).
- **Pin versions**, keep imports at file top, prefer the section file over `main.typ`
  unless the package sets document-wide state.
- **Verify the API from the cached source** (`.../packages/preview/<name>/<ver>/src/`)
  before writing non-trivial calls — parameter names change across versions.
- **Don't re-enable `justify`** inside narrow columns/headings (Thai over-stretches).
- After any add: compile with `--font-path font/`, rebuild `main.pdf`, `open` it.
