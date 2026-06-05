#!/bin/bash
set -e

# If the data directory is empty, perform a base backup from the primary
if [ -z "$(ls -A "$PGDATA")" ]; then
    echo "Data directory is empty, performing base backup from $PRIMARY_HOST..."
    export PGPASSWORD='replication_password'
    until pg_basebackup -h "$PRIMARY_HOST" -D "$PGDATA" -U replication -Fp -Xs -P -R; do
        echo "Primary ($PRIMARY_HOST) is not ready, retrying in 2 seconds..."
        sleep 2
    done
    echo "Base backup complete."
    chmod 0700 "$PGDATA"
fi

# Start PostgreSQL with any arguments passed to the script
echo "Starting PostgreSQL with: $@"
exec "$@"
