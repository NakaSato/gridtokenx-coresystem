---
description: Environment setup and configuration guide
---

# Environment Setup

Set up and configure the GridTokenX development environment. This project is optimized for macOS and requires **OrbStack** as the container runtime.

## Prerequisites

### Required Software

| Tool | Version | Purpose |
|------|---------|---------|
| **OrbStack** | Latest | High-performance Docker runtime (Mandatory for macOS) |
| Rust | 1.75+ | Backend services & Smart contracts |
| Bun | Latest | Fast JavaScript runtime & Frontend manager |
| Solana CLI | 1.18+ | Blockchain interactions |
| Anchor | 0.30+ | Smart contract framework |
| Python | 3.11+ | Simulator & local scripts |
| UV | Latest | Fast Python package manager |
| Just | Latest | Project-wide task runner |

### Installation

> [!IMPORTANT]
> **OrbStack is required.** If you are using Docker Desktop, please migrate to OrbStack to ensure compatibility with our networking and performance standards.
> ```bash
> brew install --cask orbstack
> ```

```bash
# Install Rust & Solana
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"

# Install Anchor CLI (via AVM)
cargo install --git https://github.com/coral-xyz/anchor avm --force --locked
avm install latest

# Install Development Tools
curl -fsSL https://bun.sh/install | bash
cargo install just
curl -LsSf https://astral.sh/uv/install.sh | sh
```

## Initial Setup

### 1. Clone & Submodules

```bash
git clone <repository-url>
cd gridtokenx-platform-infa
git submodule update --init --recursive
```

### 2. Run System Doctor

Use the unified manager to verify your environment health:

// turbo

```bash
./scripts/app.sh doctor
```

### 3. Environment Configuration

Copy the example configuration to your active `.env`:

```bash
cp .env.example .env
```

Key variables to review in `.env`:
- `POSTGRES_PASSWORD`: Database security.
- `JWT_SECRET`: Used for session authentication.
- `ENCRYPTION_SECRET`: Critical for user wallet encryption (IAM Service).
- `SOLANA_CLUSTER`: Default is `localnet`.

## Directory Overview

The project is organized into domain-specific microservices:

| Directory | Component | Purpose |
|-----------|-----------|---------|
| `gridtokenx-api/` | API Services | Central Gateway & Orchestrator |
| `gridtokenx-iam-service/` | IAM Service | Identity & Blockchain Registry |
| `gridtokenx-trading-service/`| Trading Service | Matching Engine & Settlement |
| `gridtokenx-oracle-bridge/` | Oracle Bridge | Telemetry Validation & Kafka |
| `gridtokenx-anchor/` | Smart Contracts | Solana Programs |
| `gridtokenx-trading/` | Trading UI | Main User Interface |

## Launching the Platform

### 1. Initialize Blockchain
This resets the local validator and deploys all programs:

// turbo

```bash
./scripts/app.sh init
```

### 2. Start Services
Launch all backend services and UIs:

// turbo

```bash
./scripts/app.sh start
```

## Verification

Check the health of all services:

// turbo

```bash
./scripts/app.sh status
```

Expected status:
- **PostgreSQL/Redis**: Running (Docker)
- **Solana Validator**: Running (Native)
- **API Services**: Running (Native/Docker)
- **Kong Gateway**: Running (Docker)

## Troubleshooting

### OrbStack Not Detected
Ensure OrbStack is running and the `docker` command points to the OrbStack context:
```bash
docker context use orbstack
```

### Port Conflicts
GridTokenX uses several ports. If a service fails to start:
```bash
./scripts/app.sh doctor
# Or manually check:
lsof -ti:4000,8000,5434 | xargs kill -9
```

### Database Migration Failures
If the database state is inconsistent:
```bash
just db-down && just db-up
just migrate
```

## Next Steps

- [Project Overview](./project-overview.md) - Deep dive into the architecture
- [Start Development](./start-dev.md) - Common development workflows
- [Testing](./testing.md) - Verify your implementation
