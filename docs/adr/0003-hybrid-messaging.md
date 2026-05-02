# ADR-0003: Hybrid Messaging (Kafka + RabbitMQ + Redis)

- **Status**: Accepted
- **Date**: 2025-04-01
- **Decision Makers**: GridTokenX Core Team

## Context

GridTokenX requires asynchronous messaging for multiple distinct use cases:

1. **Event sourcing** — durable, ordered log of trades, orders, and settlements.
2. **Task queues** — reliable job processing with retries and dead letter queues (email, settlement retries).
3. **Real-time streaming** — sub-millisecond WebSocket fan-out for price updates and order book changes.

No single messaging system excels at all three. The question was whether to standardize on one or adopt a purpose-fit approach.

## Decision

We use a **hybrid architecture** with three messaging systems, each purpose-matched:

| Technology | Role | Key Use Cases |
|:---|:---|:---|
| **Apache Kafka** (3 logical clusters) | Event sourcing log | Orders, trades, audit trails — strict ordering, 168h retention |
| **RabbitMQ** | Task queues | Email notifications, settlement retries, DLQ, guaranteed delivery |
| **Redis 7 Pub/Sub** | Real-time engine | WebSocket fan-out, session cache, sub-millisecond access |

### Kafka Cluster Design

| Cluster | Port | Purpose | Retention |
|:---|:---|:---|:---|
| `cmd-events` | 9001 | Commands, trades, settlements | 7 days |
| `market-data` | 9002 | Order book updates, prices | Ephemeral (high-TPS) |
| `audit` | 9003 | Regulatory compliance, S3-tiered | 7 years |

## Rationale

### Why Not Just Kafka?

Kafka excels at ordered event logs but is **poor at task queues**: no per-message acknowledgment, no dead letter queues, no priority queues, no delayed redelivery. Settlement retries and email notifications need exactly these features.

### Why Not Just RabbitMQ?

RabbitMQ excels at task queues but is **poor at high-throughput event streaming**: single-consumer-per-partition semantics don't apply, and there's no built-in log compaction or long-term retention for audit compliance.

### Why Not Just Redis?

Redis Pub/Sub is **fire-and-forget** — no durability, no replay. Perfect for real-time WebSocket fan-out where missed messages are acceptable (the client resyncs from the order book snapshot), but unsuitable for anything requiring guaranteed delivery.

### Why All Three?

Each system handles the workload it was designed for:

```
Kafka:    Ordered, durable event log → trades, audits, event sourcing
RabbitMQ: Reliable task processing   → email, retries, DLQ
Redis:    Ultra-low-latency pub/sub  → WebSocket, price tickers, sessions
```

## Consequences

- **Positive**: Each messaging pattern uses the optimal tool. No impedance mismatch.
- **Negative**: Three systems to operate, monitor, and debug. Increased infrastructure complexity.
- **Mitigation**: Unified observability (Prometheus metrics, Grafana dashboards). Single Docker Compose for local dev.
- **NATS JetStream**: Chain Bridge uses NATS JetStream for blockchain transaction submission (added later, purpose-specific for the durable async write path to Solana).

## References

- [ARCHITECTURE.md](../../ARCHITECTURE.md) — Port numbering for messaging systems
