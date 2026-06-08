---
description: Working with and troubleshooting the GridTokenX Aggregator Bridge
---

# Aggregator Bridge Workflow

The **Aggregator Bridge** is the high-performance ingestion layer for the GridTokenX VPP. it validates incoming IoT telemetry and bridges it to the VPP Optimization engine and the HyperEVM blockchain.

## Data Flow Architecture

The service follows a **"Sync Core, Async Edges"** pattern to maximize throughput and reliability.

### 1. Synchronous Ingestion (Path A)
- **Source**: Smart Meters, EV Chargers, BESS.
- **Protocol**: REST/JSON (Axum).
- **Security**: Mandatory Ed25519 signature verification (`{meter_id}:{kwh}:{timestamp}`).
- **Internal Storage**: Normalized readings are pushed to **Zone-Partitioned Redis Streams**.

### 2. Asynchronous Processing
- **Consumers**: Multi-threaded `ZoneEventIngester` workers.
- **Reliability**: Redis Consumer Groups with stale message reclamation.
- **Batching**: Individual readings are batched (50 per batch or 100ms timeout).

### 3. Forwarding (Path B)
- **Target**: `api-services` (Platform).
- **Protocol**: ConnectRPC (gRPC over HTTP/2).
- **Finality**: Messages are only ACKed in Redis after the platform confirms receipt.

## Troubleshooting

### Check Ingestion Health
If telemetry is not appearing in the platform, check the bridge logs for signature verification failures:

```bash
# View recent oracle bridge logs
tail -f gridtokenx-aggregator-bridge/oracle.log | grep -E "✅|🚫|❌"
```

### Redis Stream Status
The bridge uses `gridtokenx:events:zone_{idx}` streams. You can inspect them using `redis-cli`:

```bash
# Check stream length
redis-cli XLEN gridtokenx:events:zone_0

# Check consumer group status
redis-cli XINFO GROUPS gridtokenx:events:zone_0
```

### Signature Verification in Dev
In non-production environments, the bridge logs warnings for invalid signatures but still accepts the data. To force strict mode:

1. Update `.env`:
   ```env
   ENVIRONMENT=production
   ```
2. Restart the service.

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `REDIS_URL` | Redis connection string | `redis://127.0.0.1:6379` |
| `API_SERVICES_URL` | Platform gRPC endpoint | `http://localhost:4000` |
| `NUM_ZONES` | Number of zone partitions | `4` |
| `REDIS_STREAM_MAXLEN` | Cap for Redis streams | `100000` |

## Related Documentation
- [Project Overview](./project-overview.md)
- [Monitoring](./monitoring.md)
