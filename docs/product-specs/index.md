# Product Specs

What user-facing features must **do** — behavior, flows, and acceptance criteria — independent of
implementation. A product spec answers "what does the user experience and what counts as correct,"
not "how is it coded." Implementation lives in design docs and exec plans.

## Conventions

- One file per feature or user journey. Kebab-case filenames.
- Each spec states: the user and their goal, the happy-path flow, edge cases, and acceptance
  criteria phrased as testable assertions.
- Link the spec to its tracking exec-plan and to the e2e tests that prove it.

## Index

| Spec | Summary |
| :--- | :--- |
| [new-user-onboarding.md](new-user-onboarding.md) | First-run journey: signup → wallet → on-chain registration |
| [gTHB_ISSUER_SERVICE.md](gTHB_ISSUER_SERVICE.md) | gTHB issuer behavior |
| [National.md](National.md) | Deployment tiers / national-scale context |
