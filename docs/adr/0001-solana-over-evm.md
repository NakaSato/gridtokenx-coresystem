# ADR-0001: Solana (Sealevel) Over EVM Chains

- **Status**: Accepted
- **Date**: 2025-01-15
- **Decision Makers**: GridTokenX Core Team

## Context

GridTokenX needs a blockchain runtime for on-chain energy trading, settlement, and tokenization. The primary candidates were:

1. **EVM-compatible chains** (Ethereum L2s, Polygon, Avalanche C-Chain)
2. **Solana (Sealevel)** — eventually as a sovereign permissioned chain (GridChain)
3. **Substrate/Cosmos** — custom chain from scratch

## Decision

We chose **Solana's Sealevel runtime** as the execution layer, deployed initially as a localnet/devnet instance with the plan to evolve into a sovereign permissioned chain (GridChain) for production.

## Rationale

| Criterion | Solana/Sealevel | EVM (Polygon/Arbitrum) |
|:---|:---|:---|
| **Throughput** | 65,000+ TPS (parallel execution) | 1,000–4,000 TPS (sequential) |
| **Finality** | 400ms block time, sub-second | 2+ seconds (L2), 12+ seconds (L1) |
| **Cost** | Sub-cent transactions | Variable gas fees |
| **Parallel execution** | ✅ Sealevel (non-conflicting txns) | ❌ Sequential EVM |
| **Smart contract language** | Rust (Anchor framework) | Solidity |
| **Ecosystem maturity** | SPL Token-2022 with extensions | ERC-20/ERC-1155 well-established |
| **Sovereign deployment** | ✅ Runtime is open-source, BPF programs portable | ❌ Requires running an EVM chain |

### Key Factors

1. **Energy markets require high throughput.** Thousands of smart meters producing readings every 15 minutes, matched against order books in real-time. EVM's sequential execution would bottleneck at scale.
2. **Rust unifies the stack.** Backend services are Rust; Anchor smart contracts are Rust. One language, shared types, compile-time guarantees across the entire stack.
3. **Sovereign chain path.** GridTokenX plans to run a permissioned PoS-BFT chain with Thai utility validators (PEA, MEA, EGAT). Solana's runtime can be deployed as a sovereign chain without modification.
4. **Sub-cent settlement.** Energy trades can be as small as 0.1 kWh — transaction fees must be negligible.

## Consequences

- **Positive**: Unified Rust stack, parallel execution, clear path to sovereign chain.
- **Negative**: Smaller developer community than Solidity/EVM, steeper learning curve for Anchor, fewer audit firms.
- **Risk**: Anchor framework breaking changes between versions (mitigated by pinning to 1.0.0 stable).

## References

- [system-architecture.md](../architecture/specs/system-architecture.md) — GridChain sovereign chain design
- [gridtokenx-anchor/](../../gridtokenx-anchor/) — On-chain programs
