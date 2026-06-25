# Design Docs

Design docs capture **why** the system is shaped the way it is — the reasoning, trade-offs, and
invariants behind a subsystem. They expand on the high-level [`ARCHITECTURE.md`](../../ARCHITECTURE.md).

A design doc is the right home for: a subsystem's data model and lifecycle, the failure modes it
must survive, the alternatives that were rejected, and the constraints future changes must respect.

## Conventions

- One file per subsystem or cross-cutting concern. Kebab-case filenames.
- Lead with the problem and the constraints, then the chosen design, then rejected alternatives.
- When a design hardens, record the decision and its rationale inline.
- Link domain terms to the [glossary](../glossary.md).

## Index

| Doc | Summary |
| :--- | :--- |
| [core-beliefs.md](core-beliefs.md) | The non-negotiable principles every design must honor |
| [api-design-guide.md](api-design-guide.md) | API conventions across services |
| [openadr-scale-proposal.md](openadr-scale-proposal.md) | RFC: full-feature, large-scale, certifiable OpenADR (hybrid VTN) |

_Add subsystem design docs here as they are written._
