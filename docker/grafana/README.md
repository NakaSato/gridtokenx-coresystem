# GridTokenX Grafana Dashboards

> ⚠️ **Prerequisite**: OrbStack must be running. See [Setup Guide](../../README.md).

## ✅ Auto-Generated Dashboards (Like SigNoz)

All dashboards have been **automatically generated** and are **pre-configured** in Grafana!

---

## 📊 Available Dashboards

| # | Dashboard | Description | Size |
|---|-----------|-------------|------|
| 1 | **Platform Overview** | High-level health & performance overview | 23K |
| 2 | **API Performance** | Deep dive into API Gateway metrics | 15K |
| 3 | **Trading Operations** | Trading engine metrics (orders, matching, settlement) | 15K |
| 4 | **Infrastructure** | PostgreSQL, Redis, Kafka, system metrics | 18K |
| 5 | **Blockchain Monitor** | Solana blockchain interactions & smart contracts | 11K |
| 6 | **IAM Service Monitor** | Auth, sessions, security metrics | 12K |

---

## 🎯 Access Your Dashboards

### 1. Open Grafana
**URL:** http://localhost:6002  
**Login:** admin / admin

### 2. View Dashboards
- Click **Dashboards** in the left sidebar
- Open the **GridTokenX** folder
- Click any dashboard to view it

### 3. Direct Links
- [Platform Overview](http://localhost:6002/d/grafana-platform-overview/gridtokenx-platform-overview)
- [API Performance](http://localhost:6002/d/grafana-api-performance/gridtokenx-api-performance)
- [Trading Operations](http://localhost:6002/d/grafana-trading-operations/gridtokenx-trading-operations)
- [Infrastructure](http://localhost:6002/d/grafana-infrastructure/gridtokenx-infrastructure)
- [Blockchain Monitor](http://localhost:6002/d/grafana-blockchain-monitor/gridtokenx-blockchain-monitor)
- [IAM Service](http://localhost:6002/d/grafana-iam-service-monitor/gridtokenx-iam-service-monitor)

---

## 📋 Dashboard Details

### 1. Platform Overview
**Panels:**
- 🔧 Total Services
- 📊 Total Requests (5m avg)
- ⏱️ P95 Latency
- ⚠️ Error Rate
- 📈 Request Rate by Service
- ⏱️ Latency Percentiles (P50, P95, P99)
- ❌ Error Rate by Service (%)
- 🐌 Top 10 Slowest Endpoints
- 📊 Trading Activity Timeline
- ⛓️ Blockchain Operations
- 🔴 Recent Errors (Last Hour)

**Use Case:** First dashboard to check for platform health overview

---

### 2. API Performance
**Panels:**
- 📊 Requests/sec
- ⏱️ Avg Latency
- ⚠️ Error Rate
- ✅ Success Rate
- 📈 Request Rate (All Methods)
- ⏱️ Latency by Endpoint
- 🐌 Slowest Endpoints (P95)
- ❌ Endpoint Error Rates

**Use Case:** Debugging API performance, identifying slow endpoints

---

### 3. Trading Operations
**Panels:**
- 📦 Total Orders (1h)
- ✅ Matched Orders
- 💰 Settlements
- ⏱️ Avg Match Time
- 📊 Order Flow Timeline
- 📈 Bid/Ask Activity
- ⏱️ Trading Operation Latency
- 🔄 Active DCA Orders

**Use Case:** Monitor trading activity, order matching, settlements

---

### 4. Infrastructure
**Panels:**
- **PostgreSQL:**
  - 🗄️ PG Connections
  - 💾 PG Cache Hit Ratio
  - 📝 PG Transactions/sec
  - ⏱️ PG Query Duration
  - 🗄️ PG Connections Over Time

- **Redis:**
  - 💾 Redis Memory
  - ⚡ Redis Operations/sec
  - 🔑 Redis Connected Clients
  - ♻️ Redis Hit Rate

- **Kafka:**
  - 📨 Kafka Messages/sec
  - 📊 Kafka Topics
  - 👥 Kafka Consumer Lag

**Use Case:** Infrastructure capacity planning, resource bottlenecks

---

### 5. Blockchain Monitor
**Panels:**
- ⛓️ Transactions (1h)
- ✅ Success Rate
- ⏱️ Avg Confirmation Time
- 💰 Priority Fees
- 📊 Transaction Volume
- 🔌 Program Calls

**Use Case:** Monitor Solana blockchain operations, debug transaction failures

---

### 6. IAM Service Monitor
**Panels:**
- 👤 Auth Requests/sec
- ✅ Auth Success Rate
- 🔐 Active Sessions
- ⚠️ Failed Auth (5m)
- 📊 Authentication Timeline
- ⏱️ Auth Latency

**Use Case:** Monitor authentication service, security auditing

---

## 🔄 Auto-Provisioning

All dashboards are **automatically loaded** when Grafana starts via provisioning configuration:

```yaml
# docker/grafana/provisioning/dashboards/dashboards.yml
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

**Benefits:**
- ✅ No manual import required
- ✅ Auto-update on file changes
- ✅ Survives container restarts
- ✅ Version controlled

---

## 🛠️ Customize Dashboards

### Add New Panels
1. Open any dashboard
2. Click **Edit** (top right)
3. Click **Add panel**
4. Configure your query
5. Click **Apply**
6. Click **Save** (top right)

### Import Community Dashboards
1. Click **+** → **Import**
2. Enter Grafana.com dashboard ID:
   - `1860` - Node Exporter Full
   - `742` - PostgreSQL Database
   - `763` - Redis Dashboard
   - `7589` - Kafka Dashboard
3. Select Prometheus data source
4. Click **Import**

---

## 📁 File Structure

```
docker/grafana/
├── provisioning/
│   ├── datasources/
│   │   └── datasources.yml      # Auto-configured data sources
│   └── dashboards/
│       └── dashboards.yml       # Dashboard auto-import config
└── dashboards/
    ├── platform-overview.json    # Platform health overview
    ├── api-performance.json      # API metrics
    ├── trading-operations.json   # Trading engine
    ├── infrastructure.json       # DB, Redis, Kafka
    ├── blockchain-monitor.json   # Solana blockchain
    └── iam-service-monitor.json  # Auth & security
```

---

## 🚀 Regenerate Dashboards

To regenerate or modify dashboards:

```bash
# Edit the generator script
nano scripts/generate-grafana-dashboards.py

# Regenerate all dashboards
python3 scripts/generate-grafana-dashboards.py

# Restart Grafana to apply changes
docker compose restart grafana
```

---

## 📊 Metrics Sources

Dashboards pull metrics from:

| Source | Endpoint | Metrics |
|--------|----------|---------|
| API Gateway | `:4001/metrics` | HTTP requests, latency, errors |
| IAM Service | `:5010/metrics` | Auth requests, sessions |
| Trading Service | `:4020/metrics` | Orders, matching, settlements |
| PostgreSQL Exporter | `:9187` | Connections, queries, cache |
| Redis Exporter | `:9121` | Memory, operations, clients |
| Kafka Exporter | `:9308` | Messages, topics, consumer lag |
| Node Exporter | `:9100` | CPU, memory, disk, network |
| cAdvisor | `:8080` | Container metrics |

---

## ✅ SigNoz Comparison

| Feature | SigNoz | Grafana (GridTokenX) |
|---------|--------|---------------------|
| **Setup** | ❌ Complex (ClickHouse issues) | ✅ Working out of the box |
| **Dashboards** | 12 (manual import) | 6 (auto-provisioned) |
| **Data Sources** | OpenTelemetry only | Prometheus + Tempo |
| **Customization** | Limited | Extensive |
| **Community** | Growing | Massive (100k+ users) |
| **Pre-built Panels** | ClickHouse queries | PromQL (standard) |
| **Alerting** | Basic | Advanced |
| **Mobile App** | No | Yes |

---

## 🎉 You're All Set!

Your Grafana instance is now running with **6 comprehensive dashboards** that mirror the SigNoz functionality:

✅ **Platform Overview** - Like SigNoz platform-overview  
✅ **API Performance** - Like SigNoz api-performance  
✅ **Trading Operations** - Like SigNoz trading-operations  
✅ **Infrastructure** - Like SigNoz infrastructure  
✅ **Blockchain Monitor** - Like SigNoz blockchain-monitor  
✅ **IAM Service Monitor** - Additional security dashboard  

**All dashboards are:**
- ✅ Auto-loaded (no manual import)
- ✅ Pre-configured with PromQL queries
- ✅ Ready to visualize metrics
- ✅ Fully customizable

---

**Open Grafana now:** http://localhost:6002  
**Navigate to:** Dashboards → GridTokenX folder
