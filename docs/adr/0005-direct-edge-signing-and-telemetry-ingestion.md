# ADR-0005: Direct Edge Signing and Telemetry Ingestion Architecture

- **Status**: Accepted
- **Date**: 2026-05-31
- **Decision Makers**: GridTokenX Core Team

## Context

Peer-to-peer (P2P) renewable energy markets require high data integrity and non-repudiation. Fraudulent telemetry (e.g., spoofing generation figures) directly leads to illegitimate energy token minting and settlement theft. 

Historically, architectures deployed intermediate "Edge Gateways" to aggregate telemetry from multiple passive meters, sign the batch, and forward it to the cloud. However, this model introduces several drawbacks:
1. **Single Point of Failure:** Compounding multiple meters onto a single gateway exposes the microgrid to full telemetry loss if the gateway fails or is physically compromised.
2. **Loss of Provenance:** Aggregating data at a gateway obfuscates individual meter authenticity on-chain.
3. **Latency Overhead:** Edge protocol translation followed by gateway-level batching increases the edge-to-ledger latency, violating real-time market matching requirements.

Furthermore, we require ingestion pathways that support both standard web applications (HTTP JSON format) and industrial utility configurations (DLMS/COSEM binary formats).

## Decision

We decided to **collapse the intermediate Edge Gateway signing layer** and execute **cryptographic attestation directly at the source** (the Smart Meter / IoT node) using the **Ed25519** signature scheme. 

To implement this, we adopted the following architectural parameters:

1. **Digital Twin Direct Signing:** The simulated smart meter node generates the telemetry and computes the signature using its own Ed25519 private key seed.
2. **Dual Telemetry Formats:**
   * **Structured Text Path:** The signature is calculated over a colon-separated string concatenation of key metrics:
     $$\text{Payload} = \text{MeterID} \mathbin{\Vert} \text{SurplusEnergy} \mathbin{\Vert} \text{Timestamp}_{\text{seconds}}$$
   * **Binary Path:** The signature is calculated directly over raw DLMS/COSEM byte frames to match industrial utility standards.
3. **Dual Ingestion Transport Interfaces:**
   * **gRPC / ConnectRPC Endpoint:** High-performance, low-serialization channel transmitting protobuf `TelemetryRequest` objects containing Base58 encoded signatures.
   * **HTTP REST Endpoint:** Standard web service channel receiving JSON payloads for legacy client compatibility.
4. **Stateless Oracle Ingestion:** The Oracle Bridge acts as a gatekeeper, verifying signatures off-chain against registered meter public keys before streaming clean data to Apache Kafka.

## Rationale

1. **End-to-End Non-Repudiation:** Cryptographically signing data at the meter sensor level ensures data integrity is protected from the physical grid-edge all the way to the on-chain Solana settlement program.
2. **Reduced Physical Footprint:** Removing the requirement for dedicated gateway hardware lowers installation and maintenance costs for residential microgrid deployment.
3. **High Performance:** Utilizing Ed25519 signatures matches Solana's native signature scheme, allowing future optimization via direct on-chain SVM signature verification hardware-acceleration.
4. **Protocol Versatility:** Providing both JSON/REST and Binary/gRPC options ensures we can support modern green IoT devices and legacy utility meters simultaneously.

## Consequences

* **Positive:**
  * Enhanced cybersecurity model with individual meter non-repudiation.
  * Direct edge-to-cloud telemetry transmission with sub-second ingestion latencies.
  * Simpler edge simulation models (encapsulating all logic inside the smart meter digital twin).
* **Negative:**
  * Requires edge meters to have sufficient CPU capability to compute Ed25519 asymmetric signatures (approximately 1-2ms of compute time per tick).
  * Increased overhead in managing public-key registries for thousands of individual meters on-chain.

## References

- [docs/LAYERED_SYSTEM_ARCHITECTURE.md](../LAYERED_SYSTEM_ARCHITECTURE.md) — Layered System Architecture detailing the ingestion path.
- [smart_meter_simulator/devices/ami.py](../../gridtokenx-smartmeter-simulator/backend/src/smart_meter_simulator/devices/ami.py) — Telemetry generation and Ed25519 signature computation.
- [smart_meter_simulator/utils/crypto.py](../../gridtokenx-smartmeter-simulator/backend/src/smart_meter_simulator/utils/crypto.py) — Base58 Ed25519 signature utilities.
