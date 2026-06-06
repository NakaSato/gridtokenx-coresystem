"""GridTokenX E2E — Postgres test helpers (via docker exec psql, matching existing scripts)."""
import os
import subprocess

PG_CONTAINER = os.getenv("PG_CONTAINER", "gridtokenx-postgres")
PG_USER = os.getenv("PG_USER", "gridtokenx_user")
PG_DB = os.getenv("PG_DB", "gridtokenx")


def query(sql: str) -> str:
    """Run SQL via docker exec psql, return trimmed single-value/raw output."""
    out = subprocess.run(
        ["docker", "exec", "-i", PG_CONTAINER, "psql", "-U", PG_USER, "-d", PG_DB, "-t", "-A", "-c", sql],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def scalar(sql: str) -> str:
    """First value of first row."""
    return query(sql).splitlines()[0].strip() if query(sql) else ""


def user_ows_wallet_id(username: str) -> str:
    return scalar(f"SELECT ows_wallet_id FROM users WHERE username = '{username}';")


def truncate_test_data():
    """Remove e2e-created rows. Extend per-table as suites grow.
    Safe: only deletes rows with e2e markers (username/email prefixes)."""
    query("DELETE FROM users WHERE username LIKE 'e2e_%' OR email LIKE '%@grx.test';")
