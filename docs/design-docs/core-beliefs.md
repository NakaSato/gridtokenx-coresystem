# Core Beliefs

The principles that constrain every design decision in GridTokenX. A change that violates one of
these is not a judgment call — overturning one needs an explicit, recorded decision first.

## 1. The ledger is the source of truth for value

Energy assets, balances, and settlements are authoritative **on-chain**. Off-chain stores
(Postgres, InfluxDB, ClickHouse) are projections and caches, never the system of record for value.
If an off-chain view disagrees with the chain, the chain wins.

## 2. Data integrity begins at the edge

Telemetry is cryptographically attested at the source with an **Ed25519** signature before it
enters the system. The platform trusts a reading only after verifying the device signature. No
unsigned or unverifiable telemetry reaches settlement.

## 3. One door to the blockchain

All Solana interaction flows through **Chain Bridge**. Writes go via NATS JetStream; reads via
gRPC. No other service holds RPC credentials or signs transactions directly. This keeps key
custody, retry logic, and nonce handling in exactly one place.

## 4. Sync core, async edges

Business logic is **synchronous** and framework-free so it is trivially unit-testable. Async lives
only at the edges: handlers, persistence, and message consumers. Core never imports HTTP or SQL types.

## 5. Dependencies point one way

`server → api → logic → persistence → core`. Never reversed. Logic never imports HTTP; handlers
never import SQL. Traits are defined in `core`, implemented in `persistence`, wired in `server`.

## 6. Off-chain filtering protects on-chain resources

Malformed, replayed, or Sybil telemetry is rejected **before** it can consume block space or
compute. The ingestion layer is the bouncer; the chain is the vault.

## 7. Failures are explicit

No `.unwrap()` in production paths. Fallible operations return `Result` with context. Degraded-but-
functional states log `warn`; actionable failures log `error`. Silence is not a success signal.

## 8. Secrets never enter logs

Passwords, private keys, JWTs, and encryption keys are `skip`-ped in instrumentation. Wallet keys
are AES-256-GCM encrypted at rest; tx signing uses Vault Transit, not keypair files, outside dev.
