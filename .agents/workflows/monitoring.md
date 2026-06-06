---
description: Monitor GridTokenX services and metrics
---

# Monitoring & Observability

GridTokenX uses a comprehensive observability stack based on **Prometheus** (metrics), **Loki** (logs), and **Tempo** (traces), all visualized in **Grafana**.

## Quick Access

// turbo

```bash
# Verify monitoring stack status
./scripts/app.sh status

# Access UIs
# Grafana: http://localhost:3001 (admin/admin)
# Prometheus: http://localhost:9090
```

## Observability Architecture

The platform uses the **OpenTelemetry (OTEL)** collector as the primary ingestion point:
1. **Services** push metrics/traces to the OTEL Collector.
2. **OTEL Collector** exports metrics to Prometheus and traces to Tempo.
3. **Loki** pulls logs directly from Docker containers.
4. **Grafana** aggregates all three data sources for visualization.

## Prometheus Metrics

### Accessing Prometheus
Open http://localhost:9090 to run ad-hoc PromQL queries.

### Core Metrics (api-services)
| Metric | Description |
|--------|-------------|
| `http_requests_total` | Total request count |
| `connect_request_duration_seconds` | Latency for ConnectRPC calls |
| `db_pool_active_connections` | Current SQLx pool usage |
| `kafka_producer_messages_total` | Outbound event count |

### Useful PromQL Queries
```promql
# Request Rate (last 5m)
sum(rate(http_requests_total{service="api-services"}[5m]))

# P95 ConnectRPC Latency
histogram_quantile(0.95, sum(rate(connect_request_duration_seconds_bucket[5m])) by (le, method))

# Database Pool Saturation
db_pool_active_connections / db_pool_max_connections
```

## Logging (Loki)

Application logs are in JSON format and enriched with `trace_id` and `span_id`.

### Accessing Logs
1. Open Grafana → Explore.
2. Select **Loki** datasource.
3. Query by service: `{container_name="gridtokenx-api-services"}`.

### Log-to-Trace Navigation
Click on any log line containing a `trace_id` to jump directly to the distributed trace in Tempo.

## Distributed Tracing (Tempo)

GridTokenX uses tracing to follow a request from the **API Gateway** → **IAM Service** → **Solana RPC**.

### Accessing Traces
1. Open Grafana → Explore.
2. Select **Tempo** datasource.
3. Use the **Search** tab to find spans by service or trace ID.

## Service Health Endpoints

| Service | Health URL |
|---------|------------|
| **API services** | http://localhost:4000/health |
| **IAM Service** | http://localhost:50052/health | (gRPC Health) |
| **Trading Service**| http://localhost:50053/health | (gRPC Health) |
| **Oracle Bridge** | http://localhost:4010/health |

## Related Workflows
- [Grafana Stack](./grafana-stack.md) - Deep dive into LGT configuration.
- [Debugging](./debugging.md) - Using logs and traces to fix issues.
- [Start Development](./start-dev.md) - Ensuring the stack is running.
