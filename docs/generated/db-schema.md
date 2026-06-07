# Database Schema (Generated)

> ⚠️ **Generated artifact — do not hand-edit.** Regenerate after any migration change.

This file documents the PostgreSQL schema owned by the relational services (IAM, Trading). The
authoritative definition is the migration set in each service:

- IAM: `gridtokenx-iam-service/migrations/`
- Trading: `gridtokenx-trading-service/migrations/`

## Regenerating

```bash
just migrate-info        # current migration status
# then dump the live schema (dev Postgres on :7001):
pg_dump --schema-only \
  "postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx" \
  > docs/generated/db-schema.sql
```

Convert the dump (or `sqlx` offline metadata in `.sqlx/`) into the table summary below.

## Tables

_Pending first generation. Run the command above and replace this section with the per-table_
_breakdown (columns, types, keys, indexes, foreign keys)._

| Table | Service | Purpose |
| :--- | :--- | :--- |
| _tbd_ | _tbd_ | _tbd_ |
