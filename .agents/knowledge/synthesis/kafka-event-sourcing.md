# Synthesis: Kafka Event Sourcing

The GridTokenX Trading Service uses a Kafka-driven event sourcing architecture to maintain a high-performance, in-memory order book while ensuring total durability and sub-second disaster recovery.

## Data Flow

1. **Order Acceptance**: The `TradingService` receives an order via gRPC.
2. **Matching Engine**: The order is added to the in-memory book. If a match occurs, the engine generates an `OrderMatched` event.
3. **Event Persistence**: Events (Created, Updated, Matched, Cancelled) are published to the `trading.orders` Kafka topic.
4. **State Rehydration**: On service restart, the `StateRehydrator` consumes the entire topic history to reconstruct the active order book before accepting new traffic.

## Key Components

- **[OrderMatchingEngine](../../gridtokenx-trading-service/src/domain/trading/engine/mod.rs)**: The core matching logic. It propagates real user IDs (`buyer_id`, `seller_id`) for settlement.
- **[StateRehydrator](../../gridtokenx-trading-service/src/domain/trading/engine/rehydration.rs)**: Orchestrates the catch-up process. It is decoupled from the live consumer to allow for discrete unit testing.
- **[KafkaConsumer](../../gridtokenx-trading-service/src/infra/events/kafka_consumer.rs)**: A high-performance wrapper around `rdkafka` that supports both real-time streaming and "catch-up" rehydration with high-water mark detection.

## Event Payloads
Defined in [domain/events/mod.rs](../../gridtokenx-trading-service/src/domain/events/mod.rs). 

- **OrderMatchedPayload**: Contains exact IDs and precision quantities required for atomic settlement on Solana.

---
*Related Technical Patterns: [Numeric Integrity](../technical/numeric-integrity.md)*
*Source: implementation_plan for Kafka migration (2026-04-11)*
