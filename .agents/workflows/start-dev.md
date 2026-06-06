---
description: Start the GridTokenX development environment
---

# Start Development Environment

This workflow starts all required services for the GridTokenX platform using the **Unified Application Manager**.

## Primary Command

The `./scripts/app.sh` script is the "one true way" to start the platform. It handles infrastructure, blockchain initialization, and service orchestration.

// turbo

```bash
./scripts/app.sh start
```

## Advanced Startup Options

| Scenario | Command |
|----------|---------|
| **Backends Only** | `./scripts/app.sh start --skip-ui` |
| **Infrastructure Only** | `./scripts/app.sh start --docker-only` |
| **Native Development** | `./scripts/app.sh start --native-apps` (Fastest for macOS) |
| **No Blockchain** | `./scripts/app.sh start --skip-solana` |

## Startup Sequence
1. **Health Check**: Runs `doctor` to verify OrbStack and dependencies.
2. **Infrastructure**: Launches PostgreSQL, Redis, Kafka, and RabbitMQ via Docker.
3. **Solana**: Starts the local validator with the required programs pre-loaded.
4. **Bootstrap**: Initializes the energy token mint and registers authority keys.
5. **Services**: Launches API, IAM, Trading, and Oracle Bridge services.
6. **Frontend**: Launches Trading UI and Explorer.

## Service Access Map

| Component | URL / Port | Purpose |
|-----------|------------|---------|
| **API Services** | http://localhost:4000 | Primary Backend Entry |
| **Kong Gateway** | http://localhost:8000 | Production-like Gateway |
| **Trading UI** | http://localhost:3000 | User Trading Platform |
| **Explorer** | http://localhost:3002 | Blockchain History |
| **Grafana** | http://localhost:3001 | Observability Dashboards |
| **Solana RPC** | http://localhost:8899 | Blockchain RPC Endpoint |

## Verification
After starting, check the status of all processes:

// turbo

```bash
./scripts/app.sh status
```

## Logs
To view logs for all services in real-time:

// turbo

```bash
./scripts/app.sh logs
```
