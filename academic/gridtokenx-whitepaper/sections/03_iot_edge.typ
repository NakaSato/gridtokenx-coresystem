= IoT and Edge Ingestion

The reliability and integrity of the GridTokenX energy market depends entirely on the quality and trustworthiness of the physical data entering the system. The edge layer is therefore designed with the same rigor applied to the blockchain layer — every component is authenticated, every measurement is signed, and every transmission is encrypted.

== Edge Gateway Architecture

The Edge Gateway is a purpose-built software stack deployed on industrial-grade ARM hardware at the prosumer premises. It serves as the bridge between the physical energy infrastructure and the GridTokenX cloud platform.

=== Hardware Specifications

The reference hardware platform is based on a multi-core ARM or x86 processor with:
- A dedicated hardware security module (HSM) or Trusted Platform Module (TPM 2.0) for secure key storage and Ed25519 signing operations.
- Dual Ethernet interfaces: one for LAN connectivity to local devices, one for WAN uplink.
- RS-485 and optical serial interfaces for legacy DLMS/COSEM meter communication.
- 4G/LTE failover modem for resilience against fixed-line outages.
- Tamper-evident enclosure with physical intrusion detection that triggers key zeroization.

=== Software Stack

The gateway runs a minimal Linux distribution (Alpine Linux) with a containerized application stack:

```
┌─────────────────────────────────────────┐
│           Gateway Application           │
│  ┌──────────┐  ┌──────────┐  ┌───────┐ │
│  │  DLMS    │  │  OCPP    │  │Modbus │ │
│  │ Adapter  │  │ Adapter  │  │  TCP  │ │
│  └────┬─────┘  └────┬─────┘  └───┬───┘ │
│       └─────────────┼─────────────┘     │
│              ┌──────▼──────┐            │
│              │  Normalizer │            │
│              └──────┬──────┘            │
│              ┌──────▼──────┐            │
│              │  HSM Signer │            │
│              └──────┬──────┘            │
│              ┌──────▼──────┐            │
│              │  mTLS Client│            │
│              └─────────────┘            │
└─────────────────────────────────────────┘
```

== Protocol Translation

=== DLMS/COSEM (Smart Meters)

The DLMS/COSEM (Device Language Message Specification / Companion Specification for Energy Metering) protocol suite, standardized as IEC 62056 @dlms, is the dominant communication standard for smart electricity meters in Thailand and across Asia.

The DLMS Adapter implements:
- *HDLC and TCP/IP transport layers*: Supporting both serial (RS-485) and Ethernet-connected meters.
- *OBIS Code Mapping*: Translating OBIS (Object Identification System) codes to human-readable energy attributes (e.g., `1.0.1.8.0.255` → `Active Energy Import Total`).
- *Push and Pull Modes*: Supporting both meter-initiated push notifications (for real-time monitoring) and gateway-initiated polling (for scheduled interval reads).
- *Authentication*: DLMS supports three security levels (None, Low, High). GridTokenX requires High Level Security (HLS) with AES-128 encryption for all meter communications.

A normalized DLMS reading is structured as:

```json
{
  "device_id": "TH-PEA-0001-ABCD1234",
  "obis_code": "1.0.1.8.0.255",
  "attribute": "active_energy_import_wh",
  "value": 12345678,
  "unit": "Wh",
  "timestamp": "2026-04-24T16:30:00+07:00",
  "quality_flag": "VALID"
}
```

=== OCPP 2.0.1 (EV Chargers)

The Open Charge Point Protocol (OCPP) 2.0.1 @ocpp is the international standard for communication between EV charging stations and central management systems. GridTokenX's OCPP Adapter acts as a Central System, managing charger sessions and extracting energy consumption data.

Key OCPP message handlers:
- `BootNotification`: Registers the charger with the platform and initiates certificate provisioning.
- `TransactionEvent`: Captures energy delivered per charging session with start/stop timestamps.
- `MeterValues`: Receives periodic energy measurements during active sessions (configurable interval, default 60 seconds).
- `StatusNotification`: Tracks charger availability for VPP flexibility dispatch.

The OCPP Adapter translates session energy data into the same normalized JSON format as the DLMS Adapter, enabling unified downstream processing.

=== Modbus TCP (Solar Inverters and BESS)

Many residential solar inverters and battery energy storage systems (BESS) expose data via Modbus TCP. The Modbus Adapter polls configured register maps at configurable intervals (default: 30 seconds) and translates register values to normalized energy readings.

== Cryptographic Signing at the Edge

=== Ed25519 Hardware Signing

Every normalized telemetry payload is signed by the gateway's Ed25519 private key before transmission. The signing operation is performed inside the HSM/TPM, ensuring the private key is never exposed to the application layer.

The signed payload structure:

```json
{
  "payload": {
    "device_id": "TH-PEA-0001-ABCD1234",
    "gateway_id": "GTX-GW-00001",
    "readings": [...],
    "sequence_number": 98765,
    "timestamp": "2026-04-24T16:30:00+07:00"
  },
  "signature": "base64url(Ed25519Sign(sha256(payload)))",
  "public_key": "base64url(gateway_ed25519_pubkey)"
}
```

The `sequence_number` is a monotonically increasing counter stored in non-volatile memory. The Oracle Bridge rejects any payload with a sequence number less than or equal to the last accepted sequence number for that gateway, providing replay protection at the ingestion layer.

=== Key Provisioning and Rotation

Gateway key pairs are generated inside the HSM during manufacturing and never leave the device. The corresponding public key is registered in the Solana Registry Program during device onboarding. Key rotation is supported via a two-phase protocol: the new public key is pre-registered on-chain, and the gateway begins dual-signing with both old and new keys during a transition window before the old key is deactivated.

#figure(
  image("../figures/edge_pipeline.svg", width: 100%),
  caption: [IoT edge ingestion pipeline: from physical device to Kafka event stream.],
) <fig-edge>

== mTLS and Secure Ingestion Pipeline

=== Certificate Authority Hierarchy

GridTokenX operates a two-tier PKI:
- *Root CA*: Offline, air-gapped, used only to sign Intermediate CAs.
- *Intermediate CA*: Online, used to issue device certificates (for mTLS client authentication) and server certificates (for Envoy Proxy TLS termination).

Each Edge Gateway is provisioned with a unique client certificate during manufacturing, bound to its hardware serial number. Certificate revocation is managed via OCSP (Online Certificate Status Protocol) with a 1-hour maximum revocation propagation delay.

=== Ingestion Pipeline Stages

```
Edge Gateway
    │ HTTP/2 POST (mTLS)
    ▼
Envoy Proxy (mTLS Termination + Rate Limiting)
    │ HTTP/2 (internal)
    ▼
Oracle Bridge
    ├── Certificate CN validation (device ID match)
    ├── Ed25519 signature verification
    ├── JSON schema validation (Protobuf-derived)
    ├── Sequence number deduplication (Redis)
    ├── Rate limit check (per device, per zone)
    └── Kafka publish (energy.telemetry, exactly-once)
```

=== Fault Tolerance

The Edge Gateway implements a local write-ahead log (WAL) for telemetry data. If the WAN connection is unavailable, readings are buffered locally (up to 72 hours of storage at 1-minute resolution). Upon reconnection, the gateway replays buffered readings in chronological order. The Oracle Bridge handles out-of-order delivery by accepting readings with timestamps up to 24 hours in the past, enabling full data recovery after extended outages.

== Device Lifecycle Management

=== Onboarding

Device onboarding follows a four-step process:
1. *Physical Installation*: The gateway is installed and connected to the prosumer's energy infrastructure.
2. *Network Provisioning*: The gateway connects to the GridTokenX provisioning endpoint and presents its factory certificate.
3. *On-Chain Registration*: The IAM Service submits a `register_device` transaction to the Solana Registry Program, recording the gateway's public key and zone assignment.
4. *Activation*: The gateway receives its operational configuration (polling intervals, Kafka endpoints, mTLS certificates) and begins normal operation.

=== Monitoring and OTA Updates

All gateways report health metrics (CPU, memory, connectivity, signing module status) to a centralized device management service every 60 seconds. Over-the-air firmware updates are delivered via a signed update package, with rollback capability in case of update failure. The update signature is verified against the platform's code-signing certificate before installation.
