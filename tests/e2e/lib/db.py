"""GridTokenX E2E — Postgres test helpers (via docker exec psql, matching existing scripts).

DB-per-service aware: a table's assertions route to its owning service's database.
PRE-cutover every PG_DB_* defaults to the shared `gridtokenx`, so nothing changes.
POST a phase flip, override that phase's env (e.g. PG_DB_TRADING=gridtokenx_trading)
so DB-level assertions hit the DB where the data actually lives. See
docs/design-docs/db-per-service-migration.md §5c (#6b).
"""
from __future__ import annotations  # PEP 604 `str | None` on the Py3.9 e2e venv

import os
import re
import subprocess

PG_CONTAINER = os.getenv("PG_CONTAINER", "gridtokenx-postgres")
PG_USER = os.getenv("PG_USER", "gridtokenx_user")
PG_DB = os.getenv("PG_DB", "gridtokenx")  # legacy default / fallback

# Per-domain DBs — each defaults to the shared DB until that phase cuts over.
PG_DB_IAM = os.getenv("PG_DB_IAM", PG_DB)
PG_DB_TRADING = os.getenv("PG_DB_TRADING", PG_DB)
PG_DB_METER = os.getenv("PG_DB_METER", PG_DB)
PG_DB_CHAIN = os.getenv("PG_DB_CHAIN", PG_DB)

# Table -> owning-domain DB. Unlisted tables fall back to PG_DB (shared).
_TABLE_DB = {
    # IAM identity
    "users": PG_DB_IAM, "user_wallets": PG_DB_IAM, "api_keys": PG_DB_IAM,
    "iam_outbox_events": PG_DB_IAM,
    # Trading
    "trading_orders": PG_DB_TRADING, "order_matches": PG_DB_TRADING,
    "settlements": PG_DB_TRADING, "market_epochs": PG_DB_TRADING,
    "p2p_orders": PG_DB_TRADING, "p2p_config": PG_DB_TRADING,
    "vpp_clusters": PG_DB_TRADING, "outbox_events": PG_DB_TRADING,
    "trading_user_activities": PG_DB_TRADING, "trading_wallet_audit_log": PG_DB_TRADING,
    # Metering (bounded context)
    "meters": PG_DB_METER, "meter_registry": PG_DB_METER,
    "meter_readings": PG_DB_METER, "oracle_submissions": PG_DB_METER,
    # Chain bridge
    "audit_log": PG_DB_CHAIN, "dedup_effects": PG_DB_CHAIN,
    "nonce_allocations": PG_DB_CHAIN,
}


def db_for(table: str) -> str:
    """Resolve which database a table lives in (shared until its phase cuts over)."""
    return _TABLE_DB.get(table, PG_DB)


# Table references in a statement: FROM/JOIN/UPDATE/INTO <table>. Post-split a
# single statement never spans two service DBs (no cross-DB JOINs), so the first
# referenced table that maps to a non-shared DB decides the route.
_TABLE_REF = re.compile(
    r"\b(?:FROM|JOIN|UPDATE|INTO)\s+([a-zA-Z_][a-zA-Z0-9_]*)", re.IGNORECASE
)


def _auto_db(sql: str) -> str:
    """Route a bare query (no explicit db=) to the DB owning the tables it names.
    Falls back to the shared PG_DB when nothing maps to a split DB — so pre-cutover
    (every PG_DB_* == PG_DB) this is a no-op."""
    for tbl in _TABLE_REF.findall(sql):
        target = _TABLE_DB.get(tbl.lower())
        if target and target != PG_DB:
            return target
    return PG_DB


def query(sql: str, db: str | None = None) -> str:
    """Run SQL via docker exec psql, return trimmed output. `db` overrides the
    target database; when omitted the DB is inferred from the tables the SQL
    names (see `_auto_db`) so DB-per-service routing works without every call
    site threading db_for(...)."""
    out = subprocess.run(
        ["docker", "exec", "-i", PG_CONTAINER, "psql", "-U", PG_USER,
         "-d", db or _auto_db(sql),
         "-t", "-A", "-c", sql],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def scalar(sql: str, db: str | None = None) -> str:
    """First value of first row."""
    r = query(sql, db)
    return r.splitlines()[0].strip() if r else ""


def user_ows_wallet_id(username: str) -> str:
    return scalar(f"SELECT ows_wallet_id FROM users WHERE username = '{username}';",
                  db=db_for("users"))


def truncate_test_data():
    """Remove e2e-created rows. Extend per-table as suites grow.
    Safe: only deletes rows with e2e markers (username/email prefixes)."""
    query("DELETE FROM users WHERE username LIKE 'e2e_%' OR email LIKE '%@grx.test';",
          db=db_for("users"))
