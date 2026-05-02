# ADR-0004: Port Numbering Scheme

- **Status**: Accepted
- **Date**: 2025-05-01
- **Decision Makers**: GridTokenX Core Team

## Context

GridTokenX runs 30+ containers and services in development. Port conflicts and confusion were frequent — developers couldn't remember which port belonged to which service, and new services were assigned ad-hoc ports that conflicted with existing ones.

## Decision

We adopted a **structured port numbering scheme** where each range maps to a functional layer:

| Range | Layer | Examples |
|:---|:---|:---|
| **4000–4099** | API Gateway & user-facing HTTP | APISIX (4001), Envoy (4002), API Orchestrator (4000) |
| **5000–5099** | Internal gRPC service mesh | IAM gRPC (5010), Trading gRPC (5020), Oracle gRPC (5030), Chain Bridge (5040) |
| **6000–6099** | Observability & telemetry | Prometheus (6001), Grafana (6002), Loki (6003), Tempo (6004), OTEL (6006) |
| **7000–7099** | Persistence (databases, caches) | Postgres primary (7001), replica (7002), Redis (7010/7011), InfluxDB (7020), ClickHouse (7030) |
| **8000–8099** | Blockchain layer | Solana RPC (8001), WS (8002), Validator (8003), Faucet (8004) |
| **9000–9099** | Messaging layer | Kafka cmd (9001), market (9002), audit (9003), Schema Registry (9010), RabbitMQ (9030) |
| **10000–10099** | Admin & debug ports | Per-service admin panels, debug ports, health checks |
| **11000–11099** | Frontend applications | Trading UI (11001), Explorer (11002), Portal (11003) |
| **12000–12099** | Edge IoT & simulation | Smart Meter Simulator (12010), Edge Gateway MQTT/HTTP/gRPC |
| **13000–13099** | Platform infrastructure | Vault (13001), Mailpit (13060) |

### Within Each Range

Services are numbered with a team-assigned offset:
- `*010` = IAM
- `*020` = Trading
- `*030` = Oracle Bridge
- `*040` = Chain Bridge
- `*050` = Notification Service

## Rationale

1. **Predictability**: Knowing a service's function tells you its port range. "Where is the gRPC endpoint for Trading?" → 5020.
2. **Non-overlapping**: Each layer has a 100-port range, eliminating conflicts even with growth.
3. **Debugging aid**: Seeing port 9003 in a log immediately tells you it's the audit Kafka cluster without lookup.
4. **Environment parity**: Same port scheme in dev, staging, and production — only hostnames change.

## Consequences

- **Positive**: Zero port conflicts since adoption. New services self-assign ports based on the scheme.
- **Negative**: Required migrating several existing services from legacy ports (e.g., Postgres from 5434 to 7001).
- **Migration**: Completed. Legacy ports (e.g., Postgres 5434 → 7001) were updated across all services and Docker Compose files.

## References

- [ARCHITECTURE.md](../../ARCHITECTURE.md) — Port numbering scheme overview
- [.env.example](../../.env.example) — All port variables
