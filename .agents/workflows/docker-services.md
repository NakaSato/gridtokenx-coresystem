---
description: Manage Docker services (PostgreSQL, Redis, Kafka, etc.)
---

# Docker Services Management

GridTokenX uses Docker Compose to orchestrate its infrastructure. **OrbStack** is the mandatory runtime for macOS to ensure performance and networking consistency.

## Quick Management

// turbo

```bash
# Start ALL infrastructure services
./scripts/app.sh start --docker-only

# Stop and remove all containers
./scripts/app.sh stop --all
```

## Service Landscape

| Service | Container Name | Port | Purpose |
|---------|---------------|------|---------|
| **PostgreSQL** | `gridtokenx-postgres` | 5434 | Primary Database |
| **Redis** | `gridtokenx-redis` | 6379 | Persistence Worker Queue |
| **Kafka** | `gridtokenx-kafka` | 9092 | Event-sourced telemetry |
| **RabbitMQ** | `gridtokenx-rabbitmq` | 5672 | Task Queues & Retries |
| **Kong Gateway**| `gridtokenx-kong` | 8000 | API entry point |
| **Oracle Bridge**| `gridtokenx-oracle-bridge`| 4010 | IoT validation layer |

## Data Persistence

Infrastructure data is stored in named Docker volumes to survive container resets:
- `postgres_data`: SQL tables and migrations.
- `kafka_data`: Topic partitions and message history.
- `redis_data`: Stream states and cache.

To wipe all data and start from scratch:
```bash
docker-compose down -v
```

## Monitoring Stack

The observability stack is part of the infrastructure:
- **Prometheus** (Port 9090): Metrics scraping.
- **Loki** (Port 3100): Log ingestion.
- **Tempo** (Port 3200): Trace storage.
- **Grafana** (Port 3001): Unified dashboard.

## Manual Troubleshooting

### Check Container Resource Usage
```bash
docker stats
```

### Inspect Container Networks
Ensure services can talk to each other inside `gridtokenx-network`:
```bash
docker network inspect gridtokenx-network
```

### Reset a Single Service
If a specific service (e.g., Kafka) is misbehaving:
```bash
docker-compose restart kafka
```

## Related Workflows
- [Monitoring](./monitoring.md) - Using the monitoring stack.
- [Database Management](./db-manage.md) - Working with PostgreSQL.
- [Start Development](./start-dev.md) - Full environment startup.
