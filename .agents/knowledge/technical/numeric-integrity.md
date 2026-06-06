# Technical Pattern: Numeric Integrity & Solana Settlement

GridTokenX requires ultra-high precision for energy billing (kWh) and currency (SOL/Token) while strictly adhering to Solana's atomic (integer-based) data requirements.

## Precision Standards

| Unit | Precision | Scale Factor | Storage Type |
| :--- | :--- | :--- | :--- |
| **Energy** (kWh) | 9 Decimals | 1,000,000,000 | `u64` (atomic) |
| **Currency** | 6 Decimals | 1,000,000 | `u64` (atomic) |
| **Price** | 9 Decimals | 1,000,000,000 | `i64` (FastPrice) |

## Implementation Layers

### 1. Hotpath: FastPrice
To optimize the matching engine's performance, we avoid `rust_decimal` overhead in comparison loops using the [FastPrice](../../gridtokenx-trading-service/src/domain/trading/engine/fast_decimal.rs) struct. It stores a pre-normalized `i64` with 9 decimal places.

### 2. Business Logic: Decimal
We use `rust_decimal::Decimal` for all arithmetic operations (fees, wheeling charges, losses) to ensure exact precision without floating-point errors.

### 3. Blockchain: Atomic Conversion
Before submission to the Solana blockchain via [BlockchainSettlementProvider](../../gridtokenx-trading-service/src/infra/blockchain/settlement.rs), quantities are converted to atomic `u64` values:

```rust
// Example: Converter logic
let energy_atomic = (quantity * Decimal::from(1_000_000_000i64)).to_u64().unwrap();
let price_atomic = (price * Decimal::from(1_000_000i64)).to_u64().unwrap();
```

## Key Gotchas

- **Truncation**: Always use `.trunc()` or `.round_dp(9)` before converting to atomic units to ensure the scale factor doesn't overflow resulting in partial precision loss.
- **Solana Limits**: Most SPL tokens use 9 decimals. If a specific currency mint uses 6 (like USDC), the `BlockchainSettlementProvider` must adjust its scale factor accordingly.

---
*Related Synthesis: [Kafka Event Sourcing](../synthesis/kafka-event-sourcing.md)*
*Source: tests/settlement_integration_test.rs verification (2026-04-11)*
