---
description: Stop all development services for GridTokenX
---

# Stop Development Environment

This workflow provides a graceful shutdown of all platform services.

## Basic Stop

Stops all application services (API, IAM, Trading, etc.) but leaves the infrastructure (Docker containers) running for faster subsequent startups.

// turbo

```bash
./scripts/app.sh stop
```

## Full Stop (Infrastructure Cleanup)

Stops all application services AND shuts down all Docker containers (PostgreSQL, Kafka, Redis, Kong). Use this when you are finished for the day or need to reset the entire stack.

// turbo

```bash
./scripts/app.sh stop --all
```

## What Happens During Shutdown
1. **Graceful Exit**: Microservices receive a termination signal to close database connections and finish active matching rounds.
2. **Validator Halt**: The Solana test validator is stopped, and the ledger state is preserved (unless `--reset` was used on start).
3. **PID Cleanup**: Internal tracking files (`.gridtokenx.pid`) are removed.
4. **Docker Down**: If `--all` is specified, `docker-compose down` is called, releasing all system resources.

## Verification
Verify that all services have stopped successfully:

// turbo

```bash
./scripts/app.sh status
```

> [!TIP]
> If a service appears stuck or a port remains occupied, run `./scripts/app.sh doctor` to identify and resolve process conflicts.
