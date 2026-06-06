---
description: Debug and troubleshoot GridTokenX services
---

# Debugging & Troubleshooting

The decentralized nature of GridTokenX means issues can span across Edge IoT, Microservices, and Blockchain layers. Use this guide to systematically isolate and resolve faults.

## Quick Diagnostics

// turbo

```bash
# 1. Check system health and PIDs
./scripts/app.sh status

# 2. Run the environment diagnostic tool
./scripts/app.sh doctor

# 3. View global logs (if everything is in Docker)
docker-compose logs -f
```

## The Troubleshooting Hierarchy

### 1. Environment & Infrastructure
Most local issues are caused by port conflicts or OrbStack state.
- **Port Conflict**: Check ports `4000`, `8000`, `5434`, `6379`, `8899`.
- **OrbStack**: Ensure `docker context use orbstack` is active.
- **Fix**: Run `./scripts/app.sh doctor` and follow the suggestions.

### 2. Service-Level Errors
If a service is running but failing requests:
- **Metrics**: Check `http://localhost:3001` (Grafana) for elevated error rates.
- **Logs**: Use **Loki** to filter by service: `{container_name="gridtokenx-api-services"}`.
- **Fix**: Check `.env` secrets and database migration status.

### 3. Distributed Faults (Traces)
If a request is slow or failing deep in the stack:
- **Traces**: Open **Tempo** in Grafana. Search for the `trace_id` found in your API logs.
- **Fix**: Identify the specific service (IAM, Trading, or Solana) where the latency spikes.

## Service-Specific Troubleshooting

### API services (Gateway)
- **Issue**: Handlers return 500.
- **Check**: `tail -f gridtokenx-api/api.log` (if native) or `docker logs gridtokenx-api-services`.
- **Cause**: Usually a gRPC timeout when talking to `iam-service` or `trading-service`.

### IAM Service (Identity/Wallets)
- **Issue**: Wallet generation fails.
- **Cause**: Typically an incorrect or missing `ENCRYPTION_MASTER_SECRET` in `.env`.

### Oracle Bridge (IoT)
- **Issue**: Telemetry not appearing in dashboards.
- **Check**: `docker logs gridtokenx-oracle-bridge`.
- **Cause**: Signature verification failure (Ed25519) or Kafka producer backlog.

### Solana Blockchain
- **Issue**: Transactions failing or stalling.
- **Diagnosis**: 
  ```bash
  # Check local validator health
  solana balance --url http://localhost:8899
  # View program logs in real-time
  solana logs --url http://localhost:8899
  ```

## Advanced Debugging Tools

### 1. Enabling Debug Logs
```bash
# Native
export RUST_LOG=debug
cargo run

# Docker
# Update environment: RUST_LOG=debug in docker-compose.yml
```

### 2. Manual SQL Access
```bash
./scripts/app.sh db-shell
# Or
docker exec -it gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx
```

### 3. Redis Inspect
Check order book state or session cache:
```bash
docker exec -it gridtokenx-redis redis-cli
> KEYS *
> HGETALL order:book:1
```

## Verification
After applying a fix, always verify with:
1. `./scripts/app.sh status`
2. `just test` (for the specific service)

## Related Workflows
- [Monitoring](./monitoring.md) - For real-time health visualization.
- [Testing](./testing.md) - For verifying fixes with automation.
- [Start Development](./start-dev.md) - For resetting the environment.
