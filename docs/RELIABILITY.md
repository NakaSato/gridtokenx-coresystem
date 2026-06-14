# Reliability

How GridTokenX stays correct and available across edge devices, an async service mesh, and a
blockchain that can be slow or briefly unreachable.

## Failure Domains

| Domain | Dominant failures | Posture |
| :--- | :--- | :--- |
| Edge / smart meters | Dropped, delayed, or spoofed telemetry | Reject unsigned; tolerate gaps; never invent readings |
| Ingestion (Aggregator Bridge) | Burst load, malformed frames, replays | Off-chain filter + dedup before Kafka |
| Service mesh | Partial outages, message redelivery | Idempotent consumers; at-least-once assumed |
| Chain Bridge / Solana | RPC outage, congestion, nonce contention | Async submit via NATS JetStream; retry; idempotent tx |
| Persistence | DB unavailability, partial writes | Outbox pattern; transactions; chain is source of truth |

## Core Tactics

1. **Idempotency everywhere value moves.** On-chain registration, minting, and settlement must be
   safe to replay. A retried operation produces no duplicate effect.
2. **Asynchronous settlement.** Writes to the chain are queued (NATS JetStream), not synchronous, so
   a slow chain degrades latency, not correctness.
3. **Event sourcing as recovery.** Kafka logs let matching and audit state be rebuilt by replay.
4. **At-least-once, dedup on read.** Consumers assume redelivery and key on stable IDs.
5. **Fail fast on bad config.** Missing required deps (`IAM_DATABASE_URL`/`DATABASE_URL`, `REDIS_URL`)
   abort startup rather than running degraded.
6. **Backpressure at the edge.** The ingestion layer absorbs telemetry bursts so downstream and
   on-chain resources are never overwhelmed.

## Operational Surface

- Health: `./scripts/app.sh doctor`
- Status: `./scripts/app.sh status`
- macOS validator limit: scripts set `ulimit -n 65536` — required, or `solana-test-validator` panics
  with "Too many open files" on Apple Silicon under load.

## Open Reliability Work

_Track concrete gaps in [`exec-plans/tech-debt-tracker.md`](exec-plans/tech-debt-tracker.md)._
