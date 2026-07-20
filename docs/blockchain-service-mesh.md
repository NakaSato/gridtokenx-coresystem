# GridTokenX — Service Mesh & Connections

> All service-to-service connections, protocols, message buses, and port assignments.
> Ports shown are **host-side mappings from the dev `docker-compose.yml`**; container-internal
> ports differ where noted (e.g. IAM `4010→8080`, Trading `4020→8093`).
> Last reviewed: 2026-07-17

---

## 1. Service Map

```
                        [Smart Meters / Edge Gateways]
                         DLMS/COSEM · Ed25519-signed
                         AES-256-GCM per device
                              │
                    HTTPS :4030 (IoT gateway — always TLS)
                    gRPC :50051 (meter simulator ingest)
                              ▼
              ┌────────────────────────────────┐
              │  Aggregator Bridge             │
              │  IoT gateway :4030 · gRPC :5030│
              │  Ed25519 verify · decrypt      │
              │  15-min aggregation window     │
              └─────────┬──────────────────┬───┘
                        │                  │
              NATS publish           InfluxDB :8086
              chain.tx.mint          (M&V baseline, async)
                        │
                        ▼
   ┌────────────────────────────────────────────┐
   │  NATS JetStream  :4222                     │
   │  Auth: SPIFFE cert + P256 envelope signing │
   │  Subjects: chain.tx.submit / cancel / mint │
   │            (see §5 for the full set)       │
   └──────────┬─────────────────────────────────┘
              │
     consumed by
              │
              ▼
   ┌──────────────────────────────────────────┐
   │  Chain Bridge  :5040 gRPC                │
   │  ONLY service with RPC access            │
   │  Vault Transit sign · mTLS · RBAC · dedup│
   │  Requires SPIFFE cert (mTLS) to connect  │
   └──────────┬───────────────────────────────┘
              │  HTTPS mTLS
              │  Consortium RPC :8899 (NOT public)
              ▼
   [Consortium SVM — localnet / staging / production]
   (private network; no public endpoints)

   ┌──────────────────────────────────────────┐
   │  LA#2 Bid Engine  (designed)             │
   │  OpenADR VEN+BL · M&V proof submit       │
   │  BidEngine SPIFFE role                   │
   └──────────┬───────────────────────────────┘
              │ NATS chain.tx.submit (P256 signed)
              │ gRPC pull capacity ← Aggregator Bridge :5030
              │ OpenADR → MEA VTN :443 / PEA VTN :443

   ┌──────────────────────────────────────────┐
   │  Trading Service  :4020 HTTP · :5020 gRPC│
   │  CDA matching engine (trading-engine)    │
   │  REST API + NATS settlement submission   │
   └──────────┬───────────────────────────────┘
              │ NATS chain.tx.submit
              │ Kafka market:9002 (market events)
              │ Postgres :7001 (order/trade store)
              │ Redis :7010 (cache/dedup)
              │ Chain Bridge :5040 gRPC (settle query)
              │ IAM Service :4010 (auth)

   ┌──────────────────────────────────────────┐
   │  IAM Service  :4010 HTTP · :5010 gRPC    │
   │  Modular monolith (6 sub-crates)         │
   │  JWT/session · wallet registration       │
   └──────────┬───────────────────────────────┘
              │ Postgres :7001
              │ Chain Bridge :5040 gRPC (read-only)
              │ Kafka (user/verification events)

   ┌──────────────────────────────────────────┐
   │  Notification Service  :4060 HTTP · :5060│
   │  Email pipeline (verify→welcome)         │
   └──────────────────────────────────────────┘
              │ Own Postgres schema (separate migrations)
              │ Kafka consume (user events) · RabbitMQ

   ┌──────────────────────────────────────────┐
   │  Meter Service  :4062 HTTP               │
   │  Read-only meter data API                │
   └──────────────────────────────────────────┘
```

> **Ingest path note:** The implemented telemetry ingress is the Aggregator Bridge IoT
> gateway — HTTPS on host `:4030` (container `:4010`), TLS always on regardless of
> `AGGREGATOR_REQUIRE_SECURE` — plus a gRPC ingest port (`:50051`) used by the smart-meter
> simulator. An MQTT-broker ingest path (EMQX, device mTLS on `:8883`) is **(designed)**;
> no broker is deployed in the current stack.

---

## 2. Service-to-Service Connection Table

| From | To | Protocol | Subject / Path | Auth |
|---|---|---|---|---|
| Smart Meter / Edge Gateway | Aggregator Bridge | HTTPS :4030 (always TLS) | IoT gateway REST ingest | Ed25519-signed DLMS payload (fail-closed) |
| Meter simulator | Aggregator Bridge | gRPC :50051 | Ingest stream | Ed25519-signed payloads |
| Smart Meter | EMQX broker **(designed)** | MQTT over mTLS :8883 | `/meter/<device_id>/reading` | Ed25519 per-device cert |
| Aggregator Bridge | NATS | NATS publish | `chain.tx.mint` | P256 signed envelope (prod); SPIFFE cert |
| Aggregator Bridge | InfluxDB | HTTP :8086 | Write API (fire-and-forget) | InfluxDB token |
| Aggregator Bridge | Kafka | Produce | `cmd:9001`, `audit:9003` | mTLS + SASL |
| LA#2 Bid Engine **(designed)** | Aggregator Bridge | gRPC :5030 | `AggregatorBridgeService` | mTLS client cert |
| LA#2 Bid Engine **(designed)** | MEA/PEA VTN | HTTPS :443 | OpenADR 3.0 REST | OAuth 2.0 |
| LA#2 Bid Engine **(designed)** | NATS | NATS publish | `chain.tx.submit` | P256 signed envelope; SPIFFE cert |
| Trading Service | Chain Bridge | gRPC :5040 | `ChainBridgeService` (read queries) | mTLS SPIFFE SAN |
| Trading Service | NATS | NATS publish | `chain.tx.submit` | P256 signed envelope |
| Trading Service | Postgres | TCP :7001 | sqlx connection pool | TLS + password |
| Trading Service | Redis | TCP :7010 | connection pool | TLS |
| Trading Service | Kafka | Produce | `market:9002` | mTLS + SASL |
| Trading Service | IAM Service | HTTP :4010 | `/auth/verify` | JWT bearer |
| IAM Service | Chain Bridge | gRPC :5040 | Read-only queries | mTLS SPIFFE SAN |
| IAM Service | Postgres | TCP :7001 | sqlx | TLS + password |
| IAM Service | Kafka | Produce | user/verification events (fire-and-forget) | Internal |
| Notification Service | Kafka | Consume | user events (verify→welcome emails) | Internal |
| Chain Bridge | NATS | Subscribe / publish | `chain.tx.submit/cancel/mint` (consume), `chain.tx.result.*` / `chain.tx.dlq.*` (publish) | P256 envelope verify; SPIFFE cert |
| Chain Bridge | Vault | HTTPS :8200 | `POST /v1/transit/sign/gridtokenx-bridge` | Vault token |
| Chain Bridge | Consortium RPC | HTTPS :8899 | JSON-RPC | mTLS client cert (NOT public) |
| Chain Bridge | Postgres | TCP :7001 | Audit store (`PostgresAuditStore`) | TLS + password |
| Chain Bridge | Redis | TCP :7010 | Blockhash cache + dedup (`claim_or_replay`) | TLS |
| APISIX Gateway | IAM Service | HTTP (container :8080) | Upstream proxy | mTLS |
| APISIX Gateway | Trading Service | HTTP (container :8093) | Upstream proxy | mTLS |

---

## 3. Protocol Communication Map by Layer

### Layer 1 — Field (Smart Meter to Aggregator)

| Protocol | Purpose | Details |
|---|---|---|
| DLMS/COSEM (IEC 62056) | Meter reading | Binary frame: plaintext header + AES-256-GCM ciphertext |
| Ed25519 | Per-frame signature | ATECC608B hardware SE on each smart meter |
| AES-256-GCM | Frame encryption | Per-device key stored in Redis |
| HTTPS :4030 | Transport to IoT gateway | Always TLS; fail-closed on signature reject |
| MQTT/TLS :8883 **(designed)** | Broker transport (EMQX) | Device mTLS cert; not in the current stack |
| OpenADR 3.0 VEN/VTN | Demand response | REST + OAuth2; VEN polls MEA/PEA VTN |
| IEEE 2030.5 partial | DER control | DERControl adapter present; Billing/Pricing gaps |
| Kafka | Internal event bus | Dedicated brokers: cmd:9001 · market:9002 · audit:9003 |

### Layer 2 — Aggregator Bridge (Ingest to NATS)

| Direction | Protocol | Details |
|---|---|---|
| Inbound | HTTPS / gRPC ingest | Ed25519 verify + AES-256-GCM decrypt (fail-closed) |
| Inbound | OpenADR VEN | Event dedup via Redis |
| Processing | Zone routing | zone_code → zone_N Redis stream; 15-min aggregation; FrequencyMonitor |
| Outbound | NATS `chain.tx.mint` | P256-signed JSON envelope (AggregatorBridge SPIFFE role) |
| Outbound | InfluxDB Write API | Async fire-and-forget; gated on `INFLUXDB_URL` |
| Outbound | Kafka | grid/zone telemetry events |
| Outbound | gRPC :5030 | Zone capacity + readings for LA#2 Bid Engine **(designed consumer)** |

### Layer 3 — Chain Bridge (NATS to Ledger)

| Protocol | Purpose | Details |
|---|---|---|
| NATS JetStream :4222 | Async write bus | At-least-once; subjects in §5 |
| SPIFFE/SVID | Service identity | URI SAN → ServiceRole: BidEngine vs AggregatorBridge |
| mTLS | Mutual cert auth | All service-to-service connections |
| P256 ECDSA | NATS envelope signing | `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true` in staging/production |
| Vault Transit API | HSM signing | Private key never leaves Vault |
| gRPC :5040 | Sync reads | balance / account / slot |

### Layer 4 — Blockchain (Consortium SVM)

| Protocol | Purpose | Details |
|---|---|---|
| Solana Gossip UDP :8001-8009 | Consensus gossip | Noise protocol encryption; firewalled to consortium IPs only |
| JSON-RPC HTTP :8899 | Submit + query | Behind mTLS; NOT public; Chain Bridge only |
| Tower BFT | Consensus | n=7, f=2, 2f+1=5 (designed topology); PoH SHA-256 VDF |
| Anchor IDL | Program interface | Anchor 1.0.0; programs on private network only |
| SPL Token-2022 | Token standard | GRID / GRX / THBC / REC |
| WebSocket :8900 | Subscriptions | Admitted nodes only; mTLS required |

---

## 4. Network Access Requirements

| Endpoint | Port | Auth Required | Who Can Access |
|---|---|---|---|
| Aggregator Bridge IoT gateway | :4030 (HTTPS) | Ed25519-signed payload | Registered meters / edge gateways |
| Aggregator Bridge gRPC | :5030 | SPIFFE cert (mTLS) | Internal services (LA#2 Bid Engine) |
| EMQX MQTT **(designed)** | :8883 | Device mTLS cert | Registered smart meters only |
| NATS JetStream | :4222 | SPIFFE cert + P256 envelope | Admitted services only |
| Chain Bridge gRPC | :5040 | SPIFFE cert (mTLS) | Admitted services: MEA/PEA/LA#2/IAM/Trading |
| Consortium RPC | :8899 | mTLS (Chain Bridge only) | Chain Bridge ONLY — NOT public |
| Gossip UDP | :8001-8009 | Consortium IP firewall | EGAT/MEA/PEA consensus nodes only |
| InfluxDB | :8086 | InfluxDB token | Aggregator Bridge only (internal) |
| Kafka | :9001 / :9002 / :9003 | Internal mTLS + SASL | Bridge + services (internal) |
| Redis | :7010 | Password | Internal services only |
| PostgreSQL | :7001 | TLS + credentials | Internal services only |
| Vault | :8200 | Vault token | Chain Bridge only |
| APISIX Gateway | :4001 | HTTPS + JWT | Public user-facing (user API only) |

> **Important:** "Public user-facing" at APISIX :4001 means users can reach the application API. It does NOT provide any path to the blockchain layer. The blockchain, Chain Bridge, NATS, and all internal services are fully isolated from the public internet.

---

## 5. NATS JetStream (Write Bus)

**URL:** `nats://nats:4222`  
**Env:** `NATS_URL`

### Subjects (verified against Chain Bridge code)

| Subject | Direction | Publisher | Consumer | Purpose |
|---|---|---|---|---|
| `chain.tx.submit` | Pub → Sub | Trading Service, LA#2 Bid Engine (designed) | Chain Bridge | General transaction submission |
| `chain.tx.cancel` | Pub → Sub | Trading Service | Chain Bridge | Order/transaction cancellation |
| `chain.tx.mint` / `chain.tx.mintbatch` | Pub → Sub | Aggregator Bridge | Chain Bridge | Generation-mint submission (single / batched) |
| `chain.tx.status` | Request/reply | Any admitted service | Chain Bridge | Read-only on-chain confirmation-status query |
| `chain.tx.result.<id>` | Reply | Chain Bridge | Submitting service | Per-request outcome on the envelope's `reply_subject` |
| `chain.tx.dlq.<op>` | Advisory | Chain Bridge | DLQ monitor | Dead-letter advisory after redelivery exhaustion |

### NATS Envelope (production)

```json
{
  "instruction": "mint_generation | settle_offchain_match | submit_mv_proof",
  "program": "energy-token | trading | oracle",
  "accounts": ["<pubkey1>", "<pubkey2>"],
  "data": "<base64-encoded instruction data>",
  "idempotency_key": "<uuid>",
  "submitted_by": "aggregator-bridge | trading-service",
  "timestamp": 1718000000,
  "auth": {
    "key_id": "platform_admin",
    "signature": "<P256 signed payload>"
  }
}
```

**Required fields for Chain Bridge to accept:**
- `key_id` must be a registered key (default test key: `"platform_admin"`)
- `auth.signature` must verify against the P256 cert for the submitting service
- `fee_payer` must be set to `SOLANA_PAYER_KEY` value
- `ComputeBudget` instruction must be prepended for fee estimation
- `blockhash` must be current (from Chain Bridge's blockhash cache)

Enforcement: `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true` in staging/production. Dev allows unsigned.

---

## 6. Kafka Topics (Async Events + Audit)

Three dedicated single-topic brokers (`kafka-cmd`, `kafka-market`, `kafka-audit`), one per concern:

| Topic | Broker port | Purpose | Retention | Publisher |
|---|---|---|---|---|
| `cmd` | :9001 | DR command events from EGAT/MEA/PEA VTN | 24h | Aggregator Bridge |
| `market` | :9002 | P2P order/trade events from Trading Service | 168h (7d) | Trading Service |
| `audit` | :9003 | Settlement audit trail (all on-chain writes) | 168h → S3 archival | Chain Bridge |

ERC audit access to `audit:9003` (by request, not real-time; requires network admission).

---

## 7. gRPC Services

| Service | Port | Type | Methods | Caller(s) |
|---|---|---|---|---|
| Chain Bridge | :5040 | Read + command routing | `GetSlot`, `GetLatestBlockhash`, `GetBalance`, `GetAccountData`, `GetEpochInfo`, `GetSignatureStatus`, `RequestAirdrop` | Trading Service, IAM Service, LA#2 Bid Engine |
| Aggregator Bridge | :5030 (default; dev compose maps :50051 for the meter simulator) | Internal capacity/reading queries + ingest | `GetZoneCapacity`, `GetReadings`, `GetMvProof` | LA#2 Bid Engine (designed), meter simulator |

All gRPC calls use mTLS. Server SPIFFE SAN is required (`CHAIN_BRIDGE_INSECURE=false` in staging/production).

---

## 8. Port Reference

Host-side ports from the dev `docker-compose.yml` (container port in parentheses where it differs):

| Port | Service | Protocol | Scope |
|---|---|---|---|
| 4000 | API orchestrator | REST | Internal orchestration entry point |
| 4001 | APISIX Gateway | HTTPS | Public user-facing (application API only — no blockchain access) |
| 4010 | IAM Service HTTP (→8080) | REST | Internal / APISIX upstream |
| 4020 | Trading Service HTTP (→8093) | REST | Internal / APISIX upstream |
| 4030 | Aggregator Bridge IoT gateway (→4010) | HTTPS | Meter/edge ingest — always TLS |
| 4060 | Notification Service HTTP (→8080) | REST | Internal |
| 4062 | Meter Service HTTP (→8080) | REST | Internal (read-only meter data) |
| 4222 | NATS JetStream (host :9020) | NATS TCP | Internal; SPIFFE cert + P256 envelope required |
| 5010 | IAM Service gRPC (→8090) | gRPC / mTLS | Internal |
| 5020 | Trading Service gRPC (→8092) | gRPC / mTLS | Internal |
| 5030 | Aggregator Bridge gRPC | gRPC / mTLS | Internal (compose maps :50051 for the simulator) |
| 5040 | Chain Bridge gRPC | gRPC / mTLS | Internal; SPIFFE cert required |
| 5060 | Notification Service gRPC (→8090) | gRPC / mTLS | Internal |
| 7001 | PostgreSQL (→5432) | TCP | Internal |
| 7010 | Redis (→6379) | TCP | Internal |
| 8086 | InfluxDB (Aggregator Bridge; host :8087) | HTTP | Internal |
| 8200 | Vault | HTTPS | Chain Bridge only |
| 8883 | EMQX / MQTT broker **(designed)** | MQTT/TLS | Smart Meter devices (device mTLS cert) |
| 8899 | Consortium RPC (JSON-RPC) | HTTPS mTLS | Chain Bridge ONLY — NOT public |
| 8900 | Consortium RPC (WebSocket) | WSS mTLS | Chain Bridge ONLY — NOT public |
| 9001 | Kafka `cmd` broker | TCP | Internal |
| 9002 | Kafka `market` broker | TCP | Internal |
| 9003 | Kafka `audit` broker | TCP | Internal |

Consensus gossip ports (8001–8009 UDP) are consortium-internal only, firewall-restricted to consortium member IP ranges (EGAT/MEA/PEA). There is no public access path to any of these ports.

---

## 9. Transport Security Summary

| Connection | TLS | Auth | Notes |
|---|---|---|---|
| Smart Meter → Aggregator Bridge | HTTPS (always on) | Ed25519-signed DLMS payload | Per-device keypair; ATECC608B hardware SE; fail-closed |
| All internal service-to-service | mTLS | SPIFFE SAN from mTLS cert | SPIFFE SAN → ServiceRole → RBAC in Chain Bridge |
| NATS envelope (production) | Transport TLS | P256 signed payload | `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true` |
| Chain Bridge → Vault | HTTPS | Vault token | `VAULT_ADDR` env |
| Chain Bridge → Consortium RPC | HTTPS mTLS | mTLS client cert | NOT public; `CHAIN_BRIDGE_INSECURE=false` in prod |
| Chain Bridge → Postgres | TLS | Username/password | Connection pool |
| Public API (APISIX :4001) | HTTPS | JWT + session | Reaches only the application layer |

---

## 10. Chain Bridge RBAC

The Chain Bridge enforces RBAC from the SPIFFE SAN of the caller's mTLS certificate:

| SPIFFE URI | ServiceRole | Permitted instruction types |
|---|---|---|
| `spiffe://gridtokenx.th/prod/aggregator-bridge` | `AggregatorBridge` | `mint_generation`, `mint_rec`, `submit_mv_proof` |
| `spiffe://gridtokenx.th/prod/trading-service` | `TradingService` | `settle_p2p_trade`, `record_settlement_batch` |
| `spiffe://gridtokenx.th/prod/la2-bid-engine` | `BidEngine` | `submit_mv_proof`, `settle_offchain_match` — **NOT** `mint_generation` or `mint_rec` |
| `spiffe://gridtokenx.th/prod/iam-service` | `IamService` | Read-only |
| (unverified / unknown) | `Unknown` | Rejected |

---

## 11. Failure Propagation

| Component fails | Immediate effect | NATS queue behaviour | Recovery |
|---|---|---|---|
| Chain Bridge | Writes cannot proceed | NATS JetStream buffers all `chain.tx.*` messages durably | Restart Chain Bridge; NATS drains queue automatically |
| NATS | All async writes fail | Services lose write bus | Restore NATS; services reconnect; resubmit if idempotency key not seen |
| Vault | Chain Bridge cannot sign | Write pipeline pauses; NATS messages unacknowledged | Restore Vault; pipeline resumes |
| Consortium RPC | Chain Bridge cannot submit | Messages acknowledged but held; retry with backoff | RPC restored; retry succeeds |
| Redis (Aggregator Bridge) | Aggregator Bridge drops incoming meter readings (fail-closed) | No new telemetry enters system | Redis restored; Bridge self-heals |
| InfluxDB | Telemetry baseline not stored | Async fire-and-forget; settlement continues | InfluxDB restored; M&V backfill required |
| Aggregator Bridge | No new telemetry | — | Restart; missed windows not retroactively re-aggregated |
