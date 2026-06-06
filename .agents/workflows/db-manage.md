---
description: Database management commands
---

# Database Management

GridTokenX uses PostgreSQL for persistent platform state. This guide covers manual database operations for development and troubleshooting.

## Quick Connection

// turbo

```bash
# Enter the interactive psql shell for the primary database
docker exec -it gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx
```

## Database Schema

Schema management belongs to individual services. Refer to the specific service migrations for details:
- **API services**: [Migrations](./database-migrations.md)
- **IAM Service**: Identity & Access Management tables.
- **Trading Service**: Order book and settlement tables.

## Common Operations

### View Table List
```sql
\dt
```

### Check Migration History
```sql
SELECT * FROM _sqlx_migrations ORDER BY installed_on DESC;
```

### Inspect User Records (API Service)
```sql
SELECT id, email, username FROM users LIMIT 10;
```

### View Order Book (Trading Service)
```sql
SELECT id, side, energy_amount, price_per_kwh FROM trading_orders WHERE status = 'open';
```

## Recovery and Resets

⚠️ **DANGER**: The following commands will delete all local development data.

### Full Reset
If your database state is corrupted or inconsistent:

// turbo

```bash
# 1. Stop services and remove volumes
./scripts/app.sh stop --all

# 2. Restart infrastructure (recreates DB)
./scripts/app.sh start --docker-only

# 3. Apply migrations
just migrate
```

## Related Workflows
- [Database Migrations](./database-migrations.md) - Managing schema changes.
- [Docker Services](./docker-services.md) - Infrastructure management.
- [Monitoring](./monitoring.md) - Viewing database performance metrics.
