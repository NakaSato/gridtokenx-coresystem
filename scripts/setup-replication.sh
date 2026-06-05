#!/bin/bash
set -e

echo "host replication replication all md5" >> "$PGDATA/pg_hba.conf"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER replication WITH REPLICATION PASSWORD 'replication_password';
EOSQL
