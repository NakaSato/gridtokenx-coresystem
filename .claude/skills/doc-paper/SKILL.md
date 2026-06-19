---
name: Doc Paper
description: Write, fact-check, review, and proofread the Typst research paper (Paper/) against the real gridtokenx codebase. Four modes — (1) FETCH facts/docs from a target service folder and draft cited Typst prose for a paper section (may add net-new content, not only document what exists), (2) VERIFY the paper's claims against existing code and flag drift, (3) REVIEW the paper as a critical preprint reviewer / professor (rigor, contribution, gaps, structure), (4) GRAMMAR recheck the Thai-language prose for correctness and consistency. Use when the user says "doc-paper", "write/expand the paper from <service>", "verify the paper against <code>", "fact-check the paper", "review the paper like a professor", "preprint review", "recheck Thai grammar", or wants paper content grounded in the actual code.
---

## Doc Paper

The paper lives in `Paper/` (Typst, Thai-language IEEE conference style — see
`Paper/CLAUDE.md`). It documents the `gridtokenx-coresystem` superproject. This
skill keeps the paper **grounded in the real code**, not in vibes. Every
architectural claim in the paper must trace to a `path:line` in a `gridtokenx-*`
service or its `ARCHITECTURE.md`.

Four modes. Pick from the user's phrasing; if unclear, ask which one.

---

### Inputs

- **Target** = the service/folder the user names (e.g. `gridtokenx-chain-bridge`,
  `gridtokenx-trading-service`, `gridtokenx-aggregator-bridge`). If omitted, infer
  from the paper section in scope or ask once.
- **Section** = which `Paper/sections/*.typ` file is in scope. If omitted, infer
  from the topic (e.g. consensus → `settlement-model-invariants.typ`, services →
  `system-design.typ`).
- Submodules: a `gridtokenx-*` folder is its own git repo. Code + its
  `ARCHITECTURE.md` live inside it; read there, cite there.

---

### Mode 1 — FETCH (write paper prose from source)

Goal: turn what the code/docs actually say into a paragraph of the paper, with
citations, in the paper's existing style.

**FETCH may add net-new content — not only restate what the paper already has.**
You can introduce new paragraphs, subsections, figures, or whole sections that the
paper currently lacks, as long as each new claim stays grounded (`path:line` for
code facts, real BibTeX for external sources) and fits the paper's framing (a
design/architecture evaluation of a simulation). When expanding: prefer covering
real gaps the code supports over padding; flag if the user's requested expansion
has no backing in the code (offer to mark it as design intent rather than invent).

1. **Locate facts (graph first, cheap).** Use the `code-review-graph` MCP BEFORE
   Grep/Read:
   - `get_architecture_overview` / `semantic_search_nodes` / `query_graph` to find
     the relevant modules, entry points, traits, message subjects.
   - Read the target's `<service>/ARCHITECTURE.md` for the intended design, then
     spot-check against code. Fall back to `rg` (never `grep`) only if the graph
     misses.
2. **Pin every claim to `path:line`.** A number, a protocol, a port, a NATS
   subject, a consensus parameter → cite the file and line that proves it. No
   citation = it does not go in the paper. Note relative paths from repo root
   (e.g. `gridtokenx-chain-bridge/src/main.rs:155`).
3. **Draft in the paper's voice.** Thai body text; keep English technical terms
   as `ไทย (English)` on first use; match the surrounding section's tone and
   length. Use real Typst: `=`/`==`/`===` headings (auto-numbered — never
   hand-number), `@citekey` for bibliography, `@sec:label` / `@fig:label` for
   cross-refs. Add a BibTeX entry to `Paper/references.bib` if you cite a new
   external source; do NOT invent `path:line`-style citations inside the prose
   itself (those are for the verification log, not the printed text).
4. **Insert** into the right `Paper/sections/*.typ` and, if it's a new section,
   add the `#include` to `Paper/main.typ` in reading order.
5. **Compile-gate.** `cd Paper && typst compile main.typ --font-path font/ /tmp/check.pdf`.
   Must exit 0 (Typst errors on undefined `@ref`/`@cite`). Report the result.
6. **Leave a trace.** For each new claim, record `claim → path:line` (used by Mode 2).

### Mode 2 — VERIFY (fact-check paper against code)

Goal: catch drift — places where the paper asserts something the code no longer
(or never) does.

1. **Extract claims.** Read the section(s) in scope and list every checkable,
   concrete assertion: numbers (slot time, TPS, window length, port), names
   (services, instructions, PDA accounts, NATS subjects), and mechanisms
   ("X goes through Chain Bridge", "Ed25519-signed", "PoA validator set").
   Skip vague/aspirational prose ("ในอนาคต…", "คาดว่า…").
2. **Check each against code (graph first).** For each claim, find the proof in
   the target folder. Classify:
   - **CONFIRMED** — code matches; record `path:line`.
   - **DRIFT** — code says something different; record both the paper line and the
     `path:line` that contradicts it.
   - **UNVERIFIABLE** — no corresponding code (simulation-only / design intent);
     flag so it can be marked as such in the paper.
3. **Report** as a table: `section.typ:line | claim | verdict | code path:line`.
   Most-severe (DRIFT) first.
4. **Offer to fix** — for each DRIFT, either correct the paper to match code, or
   flag it as a known gap. Do not edit prose without surfacing the drift first.

### Mode 3 — REVIEW (critical preprint review, professor lens)

Goal: read the paper the way a strict conference reviewer / thesis advisor would —
judge whether it would survive peer review, and say what to fix. This is critique,
not copy-editing (grammar = Mode 4) and not fact-checking against code (= Mode 2,
though you may invoke it when a claim looks unsupported).

1. **Read the whole paper in reading order** (`main.typ` includes), not one section
   in isolation — reviewers judge the arc: motivation → gap → contribution →
   method → evaluation → limitations → conclusion.
2. **Score each dimension** (be specific, cite `section.typ:line`):
   - **Contribution & novelty** — what's actually new vs `related-work`? Is the
     claimed contribution stated clearly and supported?
   - **Rigor & soundness** — do claims follow from evidence? Overclaiming? Is the
     simulation-vs-measurement scope honest (no field-data language for sim runs)?
   - **Evaluation** — are metrics, baselines, and methodology adequate and
     reproducible? Missing baselines / ablations / error bars?
   - **Structure & clarity** — logical flow, dangling/duplicated sections (e.g.
     repeated subsections across chapters), undefined terms, figure/table payoff.
   - **Related work** — fair coverage, correct positioning, citation gaps.
   - **Reproducibility** — enough detail (params, versions, configs) to rebuild it.
3. **Output a referee report**: a short verdict (accept / minor / major / reject
   framing) + a numbered list of findings ordered by severity, each as
   `severity | section.typ:line | issue | concrete fix`. Separate **must-fix**
   (blocks acceptance) from **nice-to-have**.
4. **Do not edit prose in this mode** — review only. Offer to switch to Mode 1/4 to
   apply specific fixes the user picks.

### Mode 4 — GRAMMAR (Thai-language recheck)

Goal: proofread the Thai prose for grammar, spelling, and consistency without
changing technical meaning.

1. **Scope** — the section(s) named, or all of `Paper/sections/*.typ` if unscoped.
2. **Check** Thai spelling/typos (e.g. ออกเเบบ→ออกแบบ, repeated สระ), particle and
   classifier use, sentence-boundary run-ons, and **term consistency**: a given
   English technical term should be introduced once as `ไทย (English)` then used
   consistently; the same concept shouldn't flip between Thai and English at random.
   Respect the paper's conventions in `Paper/CLAUDE.md` (bilingual style;
   justification deliberately off in narrow columns — don't touch layout).
3. **Don't change meaning or citations.** Fix language only; never alter a number,
   a `@cite`/`@ref`, a `path:line`, or a technical claim. If a fix would change
   meaning, surface it instead of applying.
4. **Report** edits as a table `section.typ:line | before → after | reason`, then
   apply (or ask first if the batch is large), and run the compile-gate.

---

### Rules

- **Cite, don't assert** (root CLAUDE.md harness rule). Every fact ↔ `path:line`.
- **Graph before grep** — `code-review-graph` MCP first; `rg` fallback; never `grep` on files.
- **Never run `cargo`/tests from repo root** — each service is its own workspace; `cd` in first. This skill mostly reads code; if a claim needs a runtime value, say it's unverified rather than guessing.
- **Compile is the paper's test.** After any edit to `Paper/`, run the typst
  compile-gate with `--font-path font/` and report pass/fail before claiming done
  (Test-First rule).
- **Don't invent figures/citations.** If prose needs a diagram that has no file in
  `Paper/picture/`, say so — do not add a dangling `@fig` ref. If you cite a new
  paper, add the real BibTeX entry.
- **Honor the paper's framing.** It is a *design/architecture evaluation of a
  simulation*, not a field measurement. Don't write claims that contradict that
  scope.

### Output (always end with)

- **What to do** — mode chosen (FETCH / VERIFY / REVIEW / GRAMMAR), target, section.
- **What actions** — files read (with the graph queries used), prose drafted /
  claims checked / referee findings / grammar edits, compile result (modes that
  edit `Paper/` — 1 and 4 — must pass the compile-gate; 2 and 3 are read-only).
- **What result** — Mode 1: inserted prose + citations; Mode 2:
  CONFIRMED/DRIFT/UNVERIFIABLE table; Mode 3: referee report (verdict +
  severity-ordered findings); Mode 4: grammar edit table. State verified vs pending.
