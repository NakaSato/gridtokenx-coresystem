-- GridTokenX Multi-Database Initialization
-- This script runs once during the first container startup
-- (mounted at /docker-entrypoint-initdb.d/ — see docker-compose.yml).
--
-- Every database pgdog routes to must exist here. pgdog resolves each logical
-- name in docker/pgdog/pgdog.toml to a backing database on `postgres`; if the
-- backing database is missing, pgdog reports the pool as down and the owning
-- service crash-loops at startup, e.g. iam-service:
--
--   Failed to connect to PostgreSQL for migrations
--     connection pool for user "gridtokenx_user" and database
--     "gridtokenx_iam_migrate" is down
--
-- The `*_migrate` logical names in pgdog.toml are session-mode aliases onto
-- these same physical databases, so they need no CREATE of their own.
--
-- Keep this list in sync with the [[databases]] entries in
-- docker/pgdog/pgdog.toml. Each statement is idempotent, so re-running is safe.

-- 'gridtokenx' (the shared/legacy database) is created by POSTGRES_DB.

-- Per-service databases (DB-per-service split — see
-- docs/design-docs/db-per-service-migration.md).
SELECT 'CREATE DATABASE gridtokenx_noti'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gridtokenx_noti')\gexec

SELECT 'CREATE DATABASE gridtokenx_iam'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gridtokenx_iam')\gexec

SELECT 'CREATE DATABASE gridtokenx_trading'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gridtokenx_trading')\gexec

SELECT 'CREATE DATABASE gridtokenx_meter'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gridtokenx_meter')\gexec

SELECT 'CREATE DATABASE gridtokenx_chain'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gridtokenx_chain')\gexec

-- Ownership: all five are created by POSTGRES_USER, which therefore already
-- owns them. Schema is NOT created here — each database is migrated by its own
-- authority (iam-service, chain-bridge and noti-service migrate at boot;
-- gridtokenx_meter is migrated by the aggregator's dedicated `migrate` bin;
-- gridtokenx_trading is provisioned from gridtokenx-iam-service/migrations/).
