# References

External reference material vendored for offline / LLM-assisted work. These are **not** GridTokenX
docs — they are third-party specs, llms.txt bundles, and vendor guides kept here so tooling can
read them without network access.

## Convention

- Vendor / tool docs as `<tool>-llms.txt` or `<tool>-reference.md`.
- Note the source URL and the date pulled at the top of each file.
- Refresh periodically; these drift from upstream.

## Index

| File | Source | Notes |
| :--- | :--- | :--- |
| _design-system-reference-llms.txt_ | tbd | UI/design-system reference |
| _nixpacks-llms.txt_ | nixpacks.com | Build/deploy reference |
| _uv-llms.txt_ | astral.sh/uv | Python packaging reference |

_Add files as they are vendored. Empty until populated._

## External Articles

Linked reference material (not vendored — read online).

| Topic | Source | Why it matters here |
| :--- | :--- | :--- |
| Harness engineering | [openai.com/index/harness-engineering](https://openai.com/index/harness-engineering/) (OpenAI, 2026) | The discipline of building the agent's *environment* — scaffolding, docs, constraints, feedback loops. **The `ARCHITECTURE.md` set, `CLAUDE.md`, `docs/design-docs/core-beliefs.md`, and verified file:line claims in this repo are this project's harness.** Core tenets: repo = single source of truth; harness lives in the repo not the agent; constrain → inform → verify → correct → human-in-loop. |
