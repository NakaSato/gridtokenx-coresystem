---
description: Index of all GridTokenX development workflows
---

# GridTokenX Workflows Index

Complete guide to developing with the GridTokenX platform.

## Quick Start

New to GridTokenX? Follow these core steps:

1. [Environment Setup](./environment-setup.md) - Install dependencies (OrbStack focus)
2. [Project Overview](./project-overview.md) - Understand the decentralized architecture
3. [Start Development](./start-dev.md) - Launch the platform with `./scripts/app.sh start`

## Workflow Categories

### 🚀 Getting Started

| Workflow | Description |
|----------|-------------|
| [Project Overview](./project-overview.md) | Architecture, messaging, and component map |
| [Environment Setup](./environment-setup.md) | Installation and OrbStack configuration |
| [Start Development](./start-dev.md) | Launch all services (native or Docker) |
| [Stop Development](./stop-dev.md) | Graceful shutdown of the platform |

### 🏗️ Domain Service Operations

| Workflow | Description |
|----------|-------------|
| [Database Migrations](./database-migrations.md) | Schema management with SQLx |
| [Smart Meter Simulator](./smart-meter-simulator.md) | Simulate prosumer and consumer IoT devices |
| [Oracle Bridge](./oracle-bridge.md) | Ingestion, signature verification, and batching |
| [Energy Trading Agent](./agent-operations.md) | AI DCA accumulation & Grid Stability |
| [Anchor Development](./anchor-development.md) | Smart contract development (Solana/Anchor) |

### 📊 Observability & Quality

| Workflow | Description |
|----------|-------------|
| [Monitoring](./monitoring.md) | Metrics, Logs (Loki), and OpenTelemetry |
| [Grafana Stack](./grafana-stack.md) | Custom dashboards and alert rules |
| [Testing](./testing.md) | Unit, integration, and e2e test suites |

### 🔧 system Operations

| Workflow | Description |
|----------|-------------|
| [Docker Services](./docker-services.md) | Manage infrastructure (Redis, Kafka, Postgres) |
| [Database Management](./db-manage.md) | Direct PostgreSQL operations |
| [Debugging](./debugging.md) | Troubleshooting common service issues |


## Management Tools

### 1. Unified Manager (`app.sh`)

The primary tool for platform management. Use this instead of manual `docker-compose` or `cargo run` commands where possible.

// turbo

```bash
./scripts/app.sh doctor    # Check environment health
./scripts/app.sh start     # Start all services
./scripts/app.sh status    # Check service health
./scripts/app.sh init      # Reset/Init blockchain
./scripts/app.sh stop      # Stop all services
```

### 2. Task Runner (`just`)

Used for repetitive development tasks and project maintenance.

```bash
just test        # Run all test suites
just migrate     # Apply database migrations
just db-up       # Start local development infrastructure
just clippy      # Run lints across all Rust packages
```

## Service Landscape

| Service | Protocol | Internal Link |
|---------|----------|---------------|
| **API services** | REST/WS | http://localhost:4000 |
| **Kong Gateway** | HTTP/2 | http://localhost:8000 |
| **Trading UI** | Web | http://localhost:3000 |
| **Explorer** | Web | http://localhost:3002 |
| **Grafana** | Web | http://localhost:3001 |
| **Solana RPC** | RPC | http://localhost:8899 |

## Need Help?

- Read [Debugging](./debugging.md) for error recovery.
- Check [Monitoring](./monitoring.md) for real-time health.
- Visit [Project Overview](./project-overview.md) for the "Big Picture".

