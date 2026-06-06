---
description: Run tests for all GridTokenX components
---

# Testing

GridTokenX follows a rigorous testing strategy across Anchor smart contracts, Rust microservices, and end-to-end integration flows.

## Quick Commands

// turbo

```bash
# Run all unit tests across all services
just test

# Run all integration tests (Requires Solana & DB)
./scripts/run_integration_tests.sh

# Run specific service tests
cd gridtokenx-api && cargo test
cd gridtokenx-iam-service && cargo test
cd gridtokenx-trading-service && cargo test
cd gridtokenx-oracle-bridge && cargo test

# Run Anchor smart contract tests
cd gridtokenx-anchor && anchor test
```

## Test Levels

### 1. Unit Tests
Stateless tests that verify business logic without external dependencies.
```bash
# Fast feedback loop
just test
```

### 2. Microservice Integration Tests
Tests that verify the interaction between a service and its persistence layer (PostgreSQL/Redis/Kafka).
```bash
# Run service-specific integration tests
cd gridtokenx-api
cargo test --test '*' -- --ignored
```

### 3. Cross-Service (ConnectRPC) Tests
Verifies the communication between the **API services** and domain services via ConnectRPC.
```bash
# Example: Testing the IAM integration via API
cargo test -p gridtokenx-api --test test_iam_integration
```

### 4. Smart Contract Tests
Anchor tests written in TypeScript to verify on-chain state transitions.
```bash
cd gridtokenx-anchor
anchor test --skip-build
```

### 5. Platform E2E Tests
Simulates a full cycle from **Edge Ingestion** → **Oracle Bridge** → **Trading Matching** → **Solana Settlement**.

| Script | Purpose |
|--------|---------|
| `test_edge_protocol.sh` | Verifies Ed25519 signing from edge to oracle |
| `test_e2e_trading.sh` | Verifies full P2P order matching and settlement |
| `stress_test_20k.sh` | Performance verification for telemetry persistence |

## Test Environment Setup

// turbo

```bash
# Launch minimal test infrastructure
./scripts/app.sh start --docker-only --skip-solana
```

### Required Variables
Ensure your `.env` is configured for the test environment:
```bash
TEST_MODE=true
DATABASE_URL=postgresql://gridtokenx_user:password@localhost:5434/gridtokenx_test
SOLANA_RPC_URL=http://localhost:8899
```

## Advanced Verification

### Output & Logs
To see internal logs during test execution:
```bash
RUST_LOG=debug cargo test -- --nocapture
```

### Code Coverage
We use `tarpaulin` for Rust coverage reports:
```bash
cargo tarpaulin --out Html
```

## Related Workflows
- [Debugging](./debugging.md) - How to analyze why a test failed.
- [Start Development](./start-dev.md) - Preparing your local environment.
- [Build & Deploy](./build-deploy.md) - Automated CI testing.
