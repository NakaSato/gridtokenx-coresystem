# ADR-0002: Modular Monolith for Backend Services

- **Status**: Accepted
- **Date**: 2025-03-01
- **Decision Makers**: GridTokenX Core Team

## Context

As GridTokenX grew, each backend service needed an internal architecture pattern. The options were:

1. **Pure microservices** — each bounded context is a separate deployable service.
2. **Monolith** — everything in a single crate with flat modules.
3. **Modular monolith** — single deployable unit, but internally structured as isolated modules with explicit boundaries.

## Decision

We adopted the **modular monolith** pattern for complex services, starting with the IAM Service as the reference implementation.

### Structure

```
gridtokenx-iam-service/
├── Cargo.toml          # Workspace root
└── crates/
    ├── iam-server/     # Entry point, wiring
    ├── iam-api/        # REST + gRPC handlers
    ├── iam-logic/      # Business services
    ├── iam-persistence/# Data access layer
    ├── iam-protocol/   # Protobuf/ConnectRPC codegen
    └── iam-core/       # Domain models, traits, config
```

**Dependency rule**: `server → api → logic → persistence → core` (never the reverse).

## Rationale

| Criterion | Modular Monolith | Microservices | Flat Monolith |
|:---|:---|:---|:---|
| **Deployment complexity** | Low (single binary) | High (N binaries, N deploys) | Low |
| **Inter-module boundaries** | ✅ Compile-enforced by crate separation | ✅ Network boundary | ❌ Convention only |
| **Refactoring safety** | ✅ Cargo catches violations | ⚠️ Requires API contracts | ❌ Easy to break layering |
| **Latency** | In-process function calls | Network hop per call | In-process |
| **Testing** | Each crate independently testable | Requires mocks/stubs | Harder to isolate |
| **Extract to microservice later** | ✅ Clean seams already exist | Already separate | ❌ Entangled |

### "Sync Core, Async Edges"

A key sub-pattern: core business logic (`iam-logic`) uses **synchronous traits** — pure functions with no async runtime dependency. Only edges (HTTP handlers, DB repositories, message consumers) are async. This makes business logic trivially unit-testable without mocking Tokio.

## Consequences

- **Positive**: Compile-time boundary enforcement, easy to test in isolation, clear extraction path to microservices if needed.
- **Negative**: More boilerplate (6 crates per service vs 1), longer initial setup time.
- **Adoption**: IAM Service fully implemented. Trading Service uses a lighter-weight layered version (`api/core/domain/infra/services` directories within a single crate). Oracle Bridge and Chain Bridge use flat modules (simpler services don't need the full pattern).

## References

- [gridtokenx-iam-service/README.md](../../gridtokenx-iam-service/README.md) — Reference implementation
