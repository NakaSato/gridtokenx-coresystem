---
description: Database migration management with SQLx
---

# Database Migrations

GridTokenX uses **SQLx** to manage its PostgreSQL schema. Since the platform follows a microservices architecture, each service manages its own migrations to ensure domain decoupling.

## Service Migration Paths

| Service | Migration Directory | Responsibility |
|---------|---------------------|----------------|
| **API services** | `gridtokenx-api/migrations/` | Orchestration state, events, audit logs |
| **IAM Service** | `gridtokenx-iam-service/migrations/` | User profiles, wallets, KYC status |
| **Trading Service** | `gridtokenx-trading-service/migrations/` | Order book history, trade matches, settlement logs |

## Quick Commands (All Services)

The root `justfile` provides shortcuts for managing migrations.

// turbo

```bash
# Run all pending migrations for the API Service
just migrate

# View migration status for the API Service
just migrate-info

# Revert last migration for the API Service
just migrate-revert
```

## Manual Migration Management

If you need to manage migrations for a specific microservice (e.g., `iam-service`):

### 1. Create a New Migration
```bash
cd gridtokenx-iam-service
sqlx migrate add <migration_name>
```

### 2. Run Pending Migrations
```bash
cd gridtokenx-iam-service
sqlx migrate run
```

### 3. Check Migration Status
```bash
cd gridtokenx-iam-service
sqlx migrate info
```

## Writing Migrations

GridTokenX migrations use a simple `Up` and `Down` pattern in a single `.sql` file.

```sql
-- Up: Create users table
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) NOT NULL UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Down: Revert migration
DROP TABLE IF EXISTS users CASCADE;
```

### Best Practices
- **Idempotency**: Use `CREATE TABLE IF NOT EXISTS` and `DROP TABLE IF EXISTS`.
- **Transactions**: SQLx runs each migration in a transaction automatically.
- **Constraints**: Ensure foreign keys are indexed for performance.
- **Down Scripts**: NEVER skip the `Down` section; it is essential for local development resets.

## Offline Query Verification
GridTokenX uses `cargo sqlx prepare` to verify queries at compile-time without a live database.

```bash
cd <service-directory>
cargo sqlx prepare
```
This updates the `.sqlx/` directory, which MUST be committed to version control.

## Resetting the Database
If you need to wipe everything and start fresh:

// turbo

```bash
# 1. Stop services and remove volumes
./scripts/app.sh stop --all

# 2. Start infrastructure
./scripts/app.sh start --docker-only

# 3. Re-run all migrations
just migrate
# (Repeat for IAM and Trading if not covered by justfile)
```

## Related Workflows
- [API Development](./api-development.md) - Integrating migrations into handlers.
- [IAM Service](./iam-service-development.md) - Identity schema details.
- [Trading Service](./trading-service-development.md) - Matching engine persistence.
