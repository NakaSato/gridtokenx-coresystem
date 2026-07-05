# GridTokenX — Service Mesh & Connections

> All service-to-service connections, protocols, message buses, and port assignments.
> Last reviewed: June 2026

---

## 1. Service Map

```
                        [Smart Meters]
                         DLMS/COSEM
                         Ed25519-signed
                         AES-256-GCM
                              │
                    MQTT mTLS :8883
                              │
                         [EMQX]
                              │
                    internal topic push
                              ▼
              ┌────────────────────────────────┐
              │  Aggregator Bridge  :5030 gRPC  │
              │  Ed25519 verify · decrypt       │
              │  15-min aggregation window      │
              └─────────┬──────────────────┬───┘
                        │                  │
              NATS publish           InfluxDB :8086
              chain.tx.submit        (M&V baseline, async)
                        │
                        ▼
   ┌────────────────────────────────────────────┐
   │  NATS JetStream  :4222                     │
   │  Auth: SPIFFE cert + P256 envelope signing │
   │  Subjects:                                 │
   │    chain.tx.submit    (write bus)          │
   │    settlement.done    (notification)       │
   │    settlement.failed  (DLQ advisory)       │
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
              │ (also → Chain Bridge via NATS)
              │
              │ gRPC pull capacity ← Aggregator Bridge :5030
              │ OpenADR → MEA VTN :443 / PEA VTN :443

   ┌──────────────────────────────────────────┐
   │  Trading Service  :4020                  │
   │  CDA matching engine (trading-engine)    │
   │  REST API + NATS settlement events       │
   └──────────┬───────────────────────────────┘
              │ NATS chain.tx.submit
              │ Kafka market:9092 (market events)
              │ Postgres :7001 (order/trade store)
              │ Redis :7002 (cache/dedup)
              │ Chain Bridge :5040 gRPC (settle query)
              │ IAM Service :4000 (auth)

   ┌──────────────────────────────────────────┐
   │  IAM Service  :4000                      │
   │  Modular monolith (6 sub-crates)         │
   │  JWT/session · wallet registration       │
   └──────────┬───────────────────────────────┘
              │ Postgres :7001
              │ Chain Bridge :5040 gRPC (read-only)
              │ NATS :4222 (event publish)

   ┌──────────────────────────────────────────┐
   │  Notification Service  :4030             │
   │  Email pipeline (verify→welcome)         │
   └──────────────────────────────────────────┘
              │ Own Postgres schema (separate migrations)
              │ NATS :4222 (subscribe settlement events)
```

---

## 2. Service-to-Service Connection Table

| From | To | Protocol | Subject / Path | Auth |
|---|---|---|---|---|
| Smart Meter | EMQX | MQTT over mTLS :8883 | `/meter/<device_id>/reading` | Ed25519 per-device cert |
| EMQX | Aggregator Bridge | Internal push | — | Internal broker |
| Aggregator Bridge | NATS | NATS publish | `chain.tx.submit` | P256 signed envelope (prod); SPIFFE cert |
| Aggregator Bridge | InfluxDB | HTTP :8086 | Write API (fire-and-forget) | InfluxDB token |
| Aggregator Bridge | Kafka | Produce | `cmd:9001`, `audit:9003` | mTLS + SASL |
| LA#2 Bid Engine | Aggregator Bridge | gRPC :5030 | `AggregatorBridgeService` | mTLS client cert |
| LA#2 Bid Engine | MEA/PEA VTN | HTTPS :443 | OpenADR 3.0 REST | OAuth 2.0 |
| LA#2 Bid Engine | NATS | NATS publish | `chain.tx.submit` | P256 signed envelope; SPIFFE cert |
| Trading Service | Chain Bridge | gRPC :5040 | `ChainBridgeService` (read queries) | mTLS SPIFFE SAN |
| Trading Service | NATS | NATS publish | `chain.tx.submit` | P256 signed envelope |
| Trading Service | Postgres | TCP :7001 | sqlx connection pool | TLS + password |
| Trading Service | Redis | TCP :7002 | connection pool | TLS |
| Trading Service | Kafka | Produce | `market:9002` | mTLS + SASL |
| Trading Service | IAM Service | HTTP :4000 | `/auth/verify` | JWT bearer |
| IAM Service | Chain Bridge | gRPC :5040 | Read-only queries | mTLS SPIFFE SAN |
| IAM Service | Postgres | TCP :7001 | sqlx | TLS + password |
| IAM Service | NATS | Publish | `settlement.done` | P256 envelope |
| Notification Service | NATS | Subscribe | `settlement.done`, `settlement.failed` | Internal |
| Chain Bridge | NATS | Subscribe / publish | `chain.tx.submit` (consume), `settlement.done/failed` | P256 envelope verify; SPIFFE cert |
| Chain Bridge | Vault | HTTPS :8200 | `POST /v1/transit/sign/gridtokenx-bridge` | Vault token |
| Chain Bridge | Consortium RPC | HTTPS :8899 | JSON-RPC | mTLS client cert (NOT public) |
| Chain Bridge | Postgres | TCP :7001 | Audit store (`PostgresAuditStore`) | TLS + password |
| Chain Bridge | Redis | TCP :7002 | Blockhash cache + dedup (`claim_or_replay`) | TLS |
| APISIX Gateway | IAM Service | HTTP :4000 | Upstream proxy | mTLS |
| APISIX Gateway | Trading Service | HTTP :4020 | Upstream proxy | mTLS |

---

## 3. Protocol Communication Map by Layer

### Layer 1 — Field (Smart Meter to Aggregator)

| Protocol | Purpose | Details |
|---|---|---|
| DLMS/COSEM (IEC 62056) | Meter reading | Binary frame: plaintext header + AES-256-GCM ciphertext |
| Ed25519 | Per-frame signature | ATECC608B hardware SE on each smart meter |
| AES-256-GCM | Frame encryption | Per-device key stored in Redis |
| MQTT/TLS :8883 | Transport to EMQX | Device mTLS cert required |
| OpenADR 3.0 VEN/VTN | Demand response | REST + OAuth2; LA#2 VEN polls MEA/PEA VTN |
| IEEE 2030.5 partial | DER control | DERControl adapter present; Billing/Pricing gaps |
| Kafka :9092 | Internal event bus | Topics: telemetry.raw, grid.status, dispatch.cmd, audit |

### Layer 2 — Aggregator Bridge (Ingest to NATS)

| Direction | Protocol | Details |
|---|---|---|
| Inbound | DLMS from EMQX | Ed25519 verify + AES-256-GCM decrypt |
| Inbound | OpenADR VEN | Event dedup via Redis |
| Inbound | Kafka consume | telemetry.raw |
| Processing | Zone routing | zone_code → zone_N Redis stream; 15-min aggregation; FrequencyMonitor |
| Outbound | NATS chain.tx.submit | P256-signed JSON envelope (AggregatorBridge SPIFFE role) |
| Outbound | InfluxDB Write API | Async fire-and-forget; gated on `INFLUXDB_URL` |
| Outbound | Kafka grid.status | Zone telemetry events |
| Outbound | gRPC :5030 | Zone capacity + readings for LA#2 Bid Engine |

### Layer 3 — Chain Bridge (NATS to Ledger)

| Protocol | Purpose | Details |
|---|---|---|
| NATS JetStream :4222 | Async write bus | At-least-once; subjects: chain.tx.submit / settlement.done / settlement.failed |
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
| Tower BFT | Consensus | n=7, f=2, 2f+1=5; PoH SHA-256 VDF |
| Anchor IDL | Program interface | Open spec format; programs on private network only |
| SPL Token-2022 | Token standard | GRID / GRX / THBG / REC |
| WebSocket :8900 | Subscriptions | Admitted nodes only; mTLS required |

---

## 4. Network Access Requirements

| Endpoint | Port | Auth Required | Who Can Access |
|---|---|---|---|
| EMQX MQTT | :8883 | Device mTLS cert | Registered smart meters only |
| Aggregator Bridge gRPC | :5030 | SPIFFE cert (mTLS) | Internal services (LA#2 Bid Engine) |
| NATS JetStream | :4222 | SPIFFE cert + P256 envelope | Admitted services only |
| Chain Bridge gRPC | :5040 | SPIFFE cert (mTLS) | Admitted services: MEA/PEA/LA#2/IAM/Trading |
| Consortium RPC | :8899 | mTLS (Chain Bridge only) | Chain Bridge ONLY — NOT public |
| Gossip UDP | :8001-8009 | Consortium IP firewall | EGAT/MEA/PEA consensus nodes only |
| InfluxDB | :8086 | InfluxDB token | Aggregator Bridge only (internal) |
| Kafka | :9092 | Internal mTLS + SASL | Bridge + services (internal) |
| Redis | :6379 / :7002 | Password | Internal services only |
| PostgreSQL | :7001 | TLS + credentials | Internal services only |
| Vault | :8200 | Vault token | Chain Bridge only |
| APISIX Gateway | :4001 | HTTPS + JWT | Public user-facing (user API only) |

> **Important:** "Public user-facing" at APISIX :4001 means users can reach the application API. It does NOT provide any path to the blockchain layer. The blockchain, Chain Bridge, NATS, and all internal services are fully isolated from the public internet.

---

## 5. NATS JetStream (Write Bus)

**URL:** `nats://nats:4222`  
**Env:** `NATS_URL`

### Subjects

| Subject | Direction | Publisher | Consumer | Purpose |
|---|---|---|---|---|
| `chain.tx.submit` | Pub → Sub | Aggregator Bridge, Trading Service, LA#2 Bid Engine, IAM Service | Chain Bridge | All blockchain writes go through this bus |
| `settlement.done` | Pub → Sub | Chain Bridge | Trading Service, Notification Service | Write confirmed on-chain |
| `settlement.failed` | Pub → Sub | Chain Bridge | Trading Service, Notification Service | DLQ advisory — write failed after retries |

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

**Bootstrap:** `kafka:9092`

| Topic | Port | Purpose | Retention | Publisher |
|---|---|---|---|---|
| `cmd:9001` | 9001 | DR command events from EGAT/MEA/PEA VTN | 24h | Aggregator Bridge |
| `market:9002` | 9002 | P2P order/trade events from Trading Service | 168h (7d) | Trading Service |
| `audit:9003` | 9003 | Settlement audit trail (all on-chain writes) | 168h → S3 archival | Chain Bridge |

ERC audit access to `audit:9003` (by request, not real-time; requires network admission).

---

## 7. gRPC Services

| Service | Port | Type | Methods | Caller(s) |
|---|---|---|---|---|
| Chain Bridge | :5040 | Read + command routing | `GetSlot`, `GetLatestBlockhash`, `GetBalance`, `GetAccountData`, `GetEpochInfo`, `GetSignatureStatus`, `RequestAirdrop` | Trading Service, IAM Service, LA#2 Bid Engine |
| Aggregator Bridge | :5030 | Internal capacity/reading queries | `GetZoneCapacity`, `GetReadings`, `GetMvProof` | LA#2 Bid Engine |

All gRPC calls use mTLS. Server SPIFFE SAN is required (`CHAIN_BRIDGE_INSECURE=false` in staging/production).

---

## 8. Port Reference

| Port | Service | Protocol | Scope |
|---|---|---|---|
| 4000 | IAM Service HTTP | REST | Internal / APISIX upstream |
| 4001 | APISIX Gateway | HTTPS | Public user-facing (application API only — no blockchain access) |
| 4020 | Trading Service HTTP | REST | Internal / APISIX upstream |
| 4030 | Notification Service | REST | Internal |
| 4222 | NATS JetStream | NATS TCP | Internal; SPIFFE cert + P256 envelope required |
| 5030 | Aggregator Bridge gRPC | gRPC / mTLS | Internal |
| 5040 | Chain Bridge gRPC | gRPC / mTLS | Internal; SPIFFE cert required |
| 5432 | — | — | Reserved |
| 7001 | PostgreSQL | TCP | Internal |
| 7002 | Redis | TCP | Internal |
| 8086 | InfluxDB (Aggregator Bridge) | HTTP | Internal |
| 8200 | Vault | HTTPS | Chain Bridge only |
| 8883 | EMQX / MQTT broker | MQTT/TLS | Smart Meter devices (device mTLS cert) |
| 8899 | Consortium RPC (JSON-RPC) | HTTPS mTLS | Chain Bridge ONLY — NOT public |
| 8900 | Consortium RPC (WebSocket) | WSS mTLS | Chain Bridge ONLY — NOT public |
| 9001 | Kafka cmd topic | TCP | Internal |
| 9002 | Kafka market topic | TCP | Internal |
| 9003 | Kafka audit topic | TCP | Internal |
| 9092 | Kafka broker | TCP | Internal |

Consensus gossip ports (8001–8009 UDP) are consortium-internal only, firewall-restricted to consortium member IP ranges (EGAT/MEA/PEA). There is no public access path to any of these ports.

---

## 9. Transport Security Summary

| Connection | TLS | Auth | Notes |
|---|---|---|---|
| Smart Meter → EMQX | mTLS | Ed25519 device cert | Per-device keypair; ATECC608B hardware SE |
| All internal service-to-service | mTLS | SPIFFE SAN from mTLS cert | SPIFFE SAN → ServiceRole → RBAC in Chain Bridge |
| NATS envelope (production) | Transport TLS | P256 signed payload | `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true` |
| Chain Bridge → Vault | HTTPS | Vault token | `VAULT_ADDR` env |
| Chain Bridge → Consortium RPC | HTTPS mTLS | mTLS client cert | NOT public; `CHAIN_BRIDGE_INSECURE=false` in prod |
| Chain Bridge → Postgres | TLS | Username/password | Connection pool |
| Public API (APISIX :4001) | HTTPS | JWT + session | ERC Smart Grid standard OAuth; reaches only application layer |

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
| Chain Bridge | Writes cannot proceed | NATS JetStream buffers all `chain.tx.submit` messages durably | Restart Chain Bridge; NATS drains queue automatically |
| NATS | All async writes fail | Services lose write bus | Restore NATS; services reconnect; resubmit if idempotency key not seen |
| Vault | Chain Bridge cannot sign | Write pipeline pauses; NATS messages unacknowledged | Restore Vault; pipeline resumes |
| Consortium RPC | Chain Bridge cannot submit | Messages acknowledged but held; retry with backoff | RPC restored; retry succeeds |
| Redis (Aggregator Bridge) | Aggregator Bridge drops incoming meter readings (fail-closed) | No new telemetry enters system | Redis restored; Bridge self-heals |
| InfluxDB | Telemetry baseline not stored | Async fire-and-forget; settlement continues | InfluxDB restored; M&V backfill required |
| Aggregator Bridge | No new telemetry | — | Restart; missed windows not retroactively re-aggregated |
