# GridTokenX Minting E2E Flow

This document maps the end-to-end flow from smart meter telemetry ingestion to on-chain GRX token minting, as implemented in the current codebase.

## 🏗️ Architecture Flow

1. **Telemetry Ingestion**: `gridtokenx-smartmeter-simulator` (Python) → `gridtokenx-oracle-bridge` (Rust).
   - Telemetry payload is signed with an Ed25519 key representing the meter.
   - Sent via gRPC (port 50051) to the Oracle Bridge.

2. **Validation & Dissemination**: `gridtokenx-oracle-bridge` receives the payload.
   - Verifies the Ed25519 signature against the device's public key.
   - Pushes the validated reading to the **Kafka Market Cluster** (topic: `meter.readings`).

3. **Oracle Consumption**: `gridtokenx-trading-service` listens to the Kafka `meter.readings` topic.
   - Resolves the `device_id` to a `user_id` (buyer/seller).
   - Calculates the `surplus_kwh` or generated amount based on feed-in tariffs.

4. **Settlement Creation**: The `SettlementService` inside `gridtokenx-trading-service` creates a `Pending` settlement record in PostgreSQL.

5. **Blockchain Execution Preparation**: The `SettlementService` batches pending settlements.
   - Uses the `blockchain-core-compat` library to build a `mint_to_wallet` instruction or `execute_atomic_settlement` instruction depending on the flow type.
   - Serializes the transaction payload.

6. **Transaction Bridging**: `gridtokenx-trading-service` publishes the serialized transaction to **NATS JetStream** (subject: `chain.tx.submit`).

7. **Finality**: `gridtokenx-chain-bridge` acts as the Vault-backed signer.
   - Pulls the message from NATS.
   - Enforces SPIFFE-based identity mapping and program RBAC.
   - Requests a signature from HashiCorp Vault.
   - Submits the signed transaction to the Solana network (Localnet/Devnet).
   - The Solana `energy-token` smart contract mints GRX to the user's Associated Token Account (ATA).

## ✅ Verification Checklist

### 1. Telemetry & Ingestion
- [ ] **Simulator Signing**: Verify `smartmeter-simulator` uses `Ed25519` for the `device_id`.
- [ ] **Gateway Handlers**: Confirm `gridtokenx-oracle-bridge` receives the gRPC request successfully.
- [ ] **Signature Verification**: Check logs for signature verification success in `oracle-bridge`.

### 2. Message Bus
- [ ] **Kafka Dissemination**: Verify `meter.readings` topic in `kafka-market` receives the payload.

### 3. Settlement Engine
- [ ] **DB Persistence**: Query `settlements` table in `gridtokenx-postgres` for `status = 'Pending'` entries after telemetry ingestion.
- [ ] **Incentive Calculation**: Verify the calculation logic correctly scales to 9 decimals (lamports).

### 4. Blockchain Execution
- [ ] **Instruction Building**: Verify `build_mint_to_wallet_instruction` in `blockchain-core-compat` uses the correct Anchor discriminator.
- [ ] **NATS Submission**: Verify `chain.tx.submit` message is published with the serialized transaction.
- [ ] **Bridge Signing**: Confirm `gridtokenx-chain-bridge` logs `✅ Success` for transaction submission.

### 5. On-Chain State
- [ ] **Token Balance**: Use Solana CLI (`spl-token balance`) to verify the prosumer's balance increased.
- [ ] **Supply Sync**: Confirm total supply syncs correctly on the blockchain.
