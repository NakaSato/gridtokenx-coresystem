# Design

Entry point for **how** GridTokenX is built — the design philosophy and the index into detailed
design material. For the structural map see the root [`ARCHITECTURE.md`](../ARCHITECTURE.md).

## Design Philosophy

GridTokenX is a **cyber-physical system**: physical grid telemetry on one side, a trustless
financial ledger on the other, and an off-chain mesh that reconciles latency against integrity in
the middle. Every design choice trades along that axis.

The governing tension: blockchains are slow and expensive; IoT telemetry is fast and voluminous.
The system resolves this by **decoupling** four concerns into layers (edge attestation, off-chain
verification, event-sourced matching, on-chain settlement) so each can scale and fail independently.

## Pillars

1. **Verify at the edge, settle on the chain.** Trust is established by Ed25519 signatures before
   data enters; value is finalized only on Solana.
2. **One door to the chain.** Chain Bridge owns all RPC and signing.
3. **Sync core, async edges.** Testable pure logic, async only where the world forces it.
4. **Event sourcing for the market.** Kafka logs are the replayable spine of matching and audit.

Full principles: [`design-docs/core-beliefs.md`](design-docs/core-beliefs.md).

## Where Design Lives

| Topic | Location |
| :--- | :--- |
| Subsystem designs & trade-offs | [`design-docs/`](design-docs/) |
| Core beliefs | [`design-docs/core-beliefs.md`](design-docs/core-beliefs.md) |
| Reliability strategy | [`RELIABILITY.md`](RELIABILITY.md) |
| Security model | [`SECURITY.md`](SECURITY.md) |
