# Paper — AI Agent Reading Path

Reference index + reading order for any AI agent working on the `Paper/` academic paper.
Read this first, then follow the order below. Every link is relative to `Paper/`.

> **What this is:** a single Typst IEEE-conference paper (bilingual **Thai** `main.typ` + **English** `main-en.typ`)
> documenting the `gridtokenx-coresystem` superproject. Builds independently — not a code project.
> Authoritative build/convention rules live in [`CLAUDE.md`](CLAUDE.md); this file is the navigation map.

---

## 0. Before touching anything

- Read [`CLAUDE.md`](CLAUDE.md) — build rules, bilingual conventions, "rebuild + open PDF after every compile".
- Fonts are vendored → **every** compile needs `--font-path font/` or Thai/Times glyphs break.
- Two entry points share everything (template, sections' data, bib):
  - Thai:    [`main.typ`](main.typ) → `main.pdf`
  - English: [`main-en.typ`](main-en.typ) → `main-en.pdf` (passes `lang: "en"`)

### Build

```bash
# Thai
typst compile main.typ    --font-path font/ main.pdf    && open main.pdf
# English
typst compile main-en.typ --font-path font/ main-en.pdf && open main-en.pdf
# compile-check only (the paper's only "test")
typst compile main-en.typ --font-path font/ /tmp/check.pdf
```

---

## 1. Shared infrastructure (read once, edit with care — touches BOTH languages)

| File | Role |
|---|---|
| [`ieee-template.typ`](ieee-template.typ) | `ieee-conf` layout fn — page geometry, headings, figure/table styling, title block. **Language-aware**: `lang: "th"` (default) / `"en"` selects rendered labels (`บทคัดย่อ`↔`Abstract`, `รูปที่`↔`Fig.`, `ตารางที่`↔`Table`, `หัวข้อ`↔`Section`) and `text(lang/region)` which drives IEEE **bibliography** connectives (`และ/ปี/ฉบับที่/น.` ↔ `and/vol./no./pp.`). |
| [`glossary.typ`](glossary.typ) | Acronym data (AMI, CDA, PoA, …). `long` = English expansion, `description` = Thai gloss. English intro prints `long` only; Thai intro prints both. |
| [`metrics.typ`](metrics.typ) | Shared numeric constants (rates, prices in `฿/kWh`) imported by eval sections — single source of truth for figures. |
| [`references.bib`](references.bib) | BibTeX, rendered IEEE style, localized by document `lang`. |
| `font/` | Vendored TTFs: TH Sarabun New (Thai), Times New Roman (English), Courier (code). |
| `picture/` | Figures (PNG) pulled via `#figure(image(...))`. |

---

## 2. Reading order (source of truth = `#include` order in `main-en.typ` / `main.typ`)

Each section has a Thai file and an English `-en` twin. Edit the twin that matches the language you build.
Each `-en` file opens with an italic one-line lead-in summarizing its topic.

| # | Topic (one-line) | English | Thai |
|---|---|---|---|
| 1 | Rooftop-solar surplus; direct P2P blocked by grid limits + no transparent price discovery | [introduction-en.typ](sections/introduction-en.typ) | [introduction.typ](sections/introduction.typ) |
| 2 | Prior P2P-market + blockchain-settlement work, and the gap they leave | [related-work-en.typ](sections/related-work-en.typ) | [related-work.typ](sections/related-work.typ) |
| 3 | System/trust/adversary model: forged readings, replay, unauthorized mint & settlement | [threat-model-en.typ](sections/threat-model-en.typ) | [threat-model.typ](sections/threat-model.typ) |
| 4 | **Thesis** — cleanly split off-chain verification from on-chain settlement; invariants at every step | [settlement-model-invariants-en.typ](sections/settlement-model-invariants-en.typ) | [settlement-model-invariants.typ](sections/settlement-model-invariants.typ) |
| 5 | CDA pricing, fee/seller-net computation, treasury token pricing | [pricing-market-mechanism-en.typ](sections/pricing-market-mechanism-en.typ) | [pricing-market-mechanism.typ](sections/pricing-market-mechanism.typ) |
| 6 | Microservice design; Aggregator Bridge verifies Ed25519 readings before matching; Chain Bridge settles via NATS | [system-design-en.typ](sections/system-design-en.typ) | [system-design.typ](sections/system-design.typ) |
| 7 | Simulation testbed + meter-fleet workload harness (no real grid) | [experimental-setup-en.typ](sections/experimental-setup-en.typ) | [experimental-setup.typ](sections/experimental-setup.typ) |
| 8 | Ingest path: 80 meters @ 5.33 rec/s zero loss; ramp to 640 meters, loss ≤ 0.03% | [evaluation-en.typ](sections/evaluation-en.typ) | [evaluation.typ](sections/evaluation.typ) |
| 9 | Benchmarks: matching ~3.1×10⁴ pairs/s; settlement 96,707 CU/pair (~48% budget) | [evaluation-bench-en.typ](sections/evaluation-bench-en.typ) | [evaluation-bench.typ](sections/evaluation-bench.typ) |
| 10 | Fleet-scale solver throughput + live on-chain mint validation; ~0.5 tx/s, ~450 settlements/900 s window | [scale-onchain-validation-en.typ](sections/scale-onchain-validation-en.typ) | [scale-onchain-validation.typ](sections/scale-onchain-validation.typ) |
| 11 | Discussion + limitations: simulation-derived, single-run exploratory, not field-measured | [discussion_limitations-en.typ](sections/discussion_limitations-en.typ) | [discussion_limitations.typ](sections/discussion_limitations.typ) |
| 12 | Conclusion: blockchain as a thin settlement layer; value = integration; next steps | [conclusion-en.typ](sections/conclusion-en.typ) | [conclusion.typ](sections/conclusion.typ) |

> Note: `evaluation-bench-en.typ` (#9) has no top-level `=` heading — its subsections continue the EVALUATION
> section (#8). `scale-onchain-validation-en.typ` (#10) opens at `==` level, also under EVALUATION.

---

## 3. Editing rules (do not break)

- **Bilingual:** body = target language; technical terms keep English name (`ไทย (English)` on first Thai use).
- **Shared files edit both languages** — recompile *both* `main.pdf` and `main-en.pdf` after touching
  `ieee-template.typ`, `glossary.typ`, `metrics.typ`, or `references.bib`.
- **No hand-numbered headings** — use `=`/`==`/`===`; numbering is automatic. Cross-ref with `@label`, never hardcoded numbers.
- **`฿` (U+0E3F)** is the Baht currency symbol, not Thai prose — keep it in both languages.
- **Verify English build has no stray Thai:**
  ```bash
  pdftotext main-en.pdf - | rg '[\x{0E01}-\x{0E3E}\x{0E40}-\x{0E5B}]' && echo "STRAY-THAI" || echo "CLEAN"
  ```
- After any content/template change: **rebuild the affected PDF and open it** (`CLAUDE.md` rule).

---

## 4. Cross-references to the real system (for fact-checking claims)

The paper documents the parent superproject. To verify a claim against code, jump to the component in
`../` (see the repo root [`../ARCHITECTURE.md`](../ARCHITECTURE.md) §8 index) and the `doc-paper` skill
(VERIFY mode) which grounds paper prose against the actual services. Key mappings:

| Paper section | Real code (relative to repo root `../`) |
|---|---|
| Aggregator Bridge / Ed25519 ingest (#6) | `../gridtokenx-aggregator-bridge/` |
| CDA matching engine (#5, #9) | `../gridtokenx-trading-service/crates/trading-engine/` |
| On-chain settlement / mint (#4, #9, #10) | `../gridtokenx-anchor/`, `../gridtokenx-chain-bridge/` |
| Blockchain shared types | `../gridtokenx-blockchain-core/` |
