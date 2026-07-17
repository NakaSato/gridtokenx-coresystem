# GridTokenX Grafana Dashboards

> **Prerequisite**: OrbStack must be running. See [Setup Guide](../../README.md).

Grafana (`grafana/grafana:11.5.0`, compose service `grafana`) is fully provisioned from this
folder: data sources and dashboards load automatically at startup — no manual import.

## Access

- **URL:** http://localhost:6002 (`GRAFANA_PORT`, default `6002`, → container `3000`)
- **Login:** `admin` / `admin` (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` defaults; sign-up disabled)
- Dashboards live in the **GridTokenX** folder (left sidebar → Dashboards).

## Available Dashboards

All JSON files in `dashboards/` are auto-provisioned. Direct link pattern:
`http://localhost:6002/d/<uid>`.

| Dashboard | UID | Covers |
|-----------|-----|--------|
| Platform Overview | `gridtokenx-platform-overview` | Platform health: request rate, latency percentiles, error/success rates by service, trading activity |
| API Performance | `gridtokenx-api-performance` | Request rates by method/path, latency percentiles + heatmap, status-code distribution |
| Trading Operations | `gridtokenx-trading-operations` | Orders created/matched, settlements, match duration, DCA orders, success vs failure |
| Blockchain Monitor | `gridtokenx-blockchain-monitor` | Solana tx rate, success rate, confirmation times, priority fees, program calls |
| Infrastructure | `gridtokenx-infrastructure` | PostgreSQL (connections, cache hit, tx rate, slow queries), Redis, Kafka |
| IAM Service Monitor | `gridtokenx-iam-service-monitor` | Auth requests, success rate, active sessions, failed auth, auth latency |
| IAM Service | `gridtokenx-iam-service` | Deeper IAM observability |
| Service Health | `gridtokenx-service-health` | Per-service health status |
| Service Map | `gridtokenx-service-map` | Inter-service call topology |
| Error Analysis | `gridtokenx-error-analysis` | Error breakdown across services |
| Logs Overview | `gridtokenx-logs-overview` | Loki log volumes and errors |
| Mint Pipeline | `gridtokenx-mint-pipeline` | Surplus-mint pipeline (aggregator → chain bridge) |
| Settlement Health | `settlement-health` | Settlement pipeline health |
| Aggregator Bridge Monitoring | `aggregator-bridge` | Telemetry ingest and aggregation |
| VPP Monitor | `vpp-monitor` | Virtual power plant metrics |
| APM Service Metrics | `apm-metrics` | Cross-service APM metrics |
| Docker Container Monitoring | `docker-containers` | Container CPU/memory (cAdvisor) |
| Node Exporter Full | `node-exporter-full` | Host CPU, memory, disk, network |

## Provisioning

Dashboards are auto-loaded via `provisioning/dashboards/dashboards.yml`:

```yaml
apiVersion: 1
providers:
  - name: 'GridTokenX APM Dashboards'
    orgId: 1
    folder: 'GridTokenX'
    type: file
    disableDeletion: false
    editable: true
    allowUiUpdates: true
    updateIntervalSeconds: 15
    options:
      path: /etc/grafana/dashboards
      foldersFromFilesStructure: true
```

Edits to the JSON files are picked up every 15 s (`updateIntervalSeconds`) — no restart needed.
Dashboards survive container restarts and are version-controlled.

Data sources (`provisioning/datasources/datasources.yml`):

| Name | Type | URL | Notes |
|------|------|-----|-------|
| Prometheus | prometheus | `http://prometheus:9090` | Default data source |
| Loki | loki | `http://loki:3100` | Derived field links `"trace_id"` in JSON logs to Tempo |
| Tempo | tempo | `http://tempo:3200` | Service map + node graph on Prometheus, trace→logs via Loki |

## File Structure

```
docker/grafana/
├── provisioning/
│   ├── datasources/
│   │   └── datasources.yml      # Prometheus + Loki + Tempo (auto-configured)
│   └── dashboards/
│       └── dashboards.yml       # Dashboard auto-import config
└── dashboards/                  # 18 provisioned dashboard JSONs (see table above)
```

Mounted read-only into the container (`docker-compose.yml`, `grafana:` block):
`provisioning/` → `/etc/grafana/provisioning/...`, `dashboards/` → `/etc/grafana/dashboards`.

## Customize Dashboards

### Add or edit panels in the UI
1. Open a dashboard → **Edit** → **Add panel** → configure the query → **Apply** → **Save**.
2. To persist a UI change into the repo, export the dashboard JSON and update the file in
   `dashboards/` (provisioned files are the source of truth on restart).

### Import community dashboards
1. Click **+** → **Import** and enter a Grafana.com dashboard ID:
   - `1860` — Node Exporter Full
   - `742` — PostgreSQL Database
   - `763` — Redis Dashboard
   - `7589` — Kafka Dashboard
2. Select the Prometheus data source → **Import**.

## Metrics Sources

Dashboards query Prometheus, which scrapes (see `docker/prometheus/prometheus.yml`):

| Job | Target | Notes |
|-----|--------|-------|
| aggregator-bridge | `aggregator-bridge:4010` | HTTPS `/metrics` behind mTLS (dev client cert) |
| iam-service | `iam-service:8080` | |
| chain-bridge | `chain-bridge:9464` | Dedicated plaintext metrics port (gRPC stays on 5040) |
| trading-service | `trading-service:8093` | |
| meter-service | `meter-service:8080` | |
| noti-service | `noti-service:8080` | |
| infrastructure | `postgres-exporter:9187`, `redis-exporter:9121`, `kafka-exporter:9308`, `node-exporter:9100`, `cadvisor:8080` | |
| pgdog | `pgdog:9090` | Native OpenMetrics endpoint |
