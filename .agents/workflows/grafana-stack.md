---
description: How to use and manage the Grafana Observability Stack (LGT)
---

# Grafana Observability Stack (LGT)

GridTokenX uses the **LGT Stack** (Loki, Grafana, Tempo) for unified observability. This workflow guides you through analyzing metrics, logs, and traces.

## 1. Stack Components

- **Grafana (Port 3001)**: The unified visualization dashboard.
- **Prometheus (Port 9090)**: Time-series database for metrics.
- **Loki (Port 3100)**: Log aggregation system.
- **Tempo (Port 3200)**: Distributed tracing backend.
- **OTEL Collector (Port 4317/4318)**: OpenTelemetry ingestion gateway.

## 2. Starting the Stack

The stack is managed by the unified application script but can be launched independently:

// turbo

```bash
./scripts/app.sh start --docker-only
```

## 3. Telemetry Exploration

### Viewing Logs in Loki
1. Navigate to **Explore** in Grafana.
2. Select **Loki**.
3. Use labels to find logs: `{container_name="gridtokenx-api-services"}`.

### Distributed Tracing in Tempo
1. Navigate to **Explore** in Grafana.
2. Select **Tempo**.
3. Use the **Search** tab to find traces by service name or custom tags.
4. **Service Graph**: View the interaction map between services to find bottlenecks.

## 4. Verification

### Check Ingestion Health
Verify that the OTEL Collector is receiving data:

// turbo

```bash
docker logs gridtokenx-otel-collector
```

Look for "Receiver: grpc" or "Exporter: prometheus" activity.

### Data Source Health
In Grafana → Administration → Data Sources, ensure **Solana_Prometheus**, **Loki**, and **Tempo** all pass the "Save & Test" check.

## 5. Persistence & Resets

Telemetry data is persisted in Docker volumes. To reset all monitoring data:

// turbo

```bash
docker-compose down -v
# This removes: grafana_data, prometheus_data, loki_data, etc.
```

## 6. Troubleshooting

- **No Metrics**: Check if the service has `OTEL_EXPORTER_OTLP_ENDPOINT` set to `http://gridtokenx-otel-collector:4317`.
- **No Logs**: Ensure the service in `docker-compose.yml` uses the `json-file` logging driver (Loki scrapes these files).
- **Latency High**: Check Tempo spans for "Database Query" or "Solana RPC" to identify the slow component.

## Related Workflows
- [Monitoring](./monitoring.md) - General metrics and dashboard list.
- [Debugging](./debugging.md) - Using LGT to solve bugs.
