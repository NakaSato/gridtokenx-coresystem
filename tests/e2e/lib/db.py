"""GridTokenX E2E — Postgres test helpers (via docker exec psql, matching existing scripts).

DB-per-service aware: a table's assertions route to its owning service's database.
Each PG_DB_* now defaults to the database that phase ACTUALLY cut over to; override
the env to point a phase elsewhere. See docs/design-docs/db-per-service-migration.md
§5c (#6b).

These used to default to the shared `gridtokenx` on the "pre-cutover, so nothing
changes" principle — correct when written, wrong once the phases landed. `users`
now lives only in gridtokenx_iam, so 90_golden_path died with a bare
CalledProcessError from psql (relation "users" does not exist) that named neither
the table nor the database. The same stale default was fixed in
test-registration-e2e.sh, test-prosumer1.sh and e2e_two_user_trade.sh.
"""
from __future__ import annotations  # PEP 604 `str | None` on the Py3.9 e2e venv

import os
import re
import subprocess

PG_CONTAINER = os.getenv("PG_CONTAINER", "gridtokenx-postgres")
PG_USER = os.getenv("PG_USER", "gridtokenx_user")
PG_DB = os.getenv("PG_DB", "gridtokenx")  # legacy default / fallback

# Per-domain DBs. Defaults are the post-cutover homes; a phase that has NOT cut
# over in some environment can be pointed back with e.g. PG_DB_METER=gridtokenx.
PG_DB_IAM = os.getenv("PG_DB_IAM", "gridtokenx_iam")
PG_DB_TRADING = os.getenv("PG_DB_TRADING", "gridtokenx_trading")
PG_DB_METER = os.getenv("PG_DB_METER", "gridtokenx_meter")
PG_DB_CHAIN = os.getenv("PG_DB_CHAIN", "gridtokenx_chain")

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


def grant_verified_meter(user_id: str, serial: str | None = None) -> str:
    """Give `user_id` a VERIFIED meter so Trading will admit their sell orders.

    Trading refuses a sell (403) unless the seller owns a verified meter, and it
    answers that from its own `meter_read_model` — a projection fed by
    meter-service `MeterRegistered`/`MeterUpdated` Kafka events. A suite that only
    exercises the CDA has no business standing up meter registration, signed
    telemetry and the verification handshake just to place an ask, so this writes
    the projection directly. It is the same kind of backdoor 90_golden_path uses
    for meter->owner mapping in Redis.

    Deliberately does NOT touch metering `meters`: this seeds only what the gate
    reads. A suite that needs the real registry row should drive the meter-service
    API instead. Returns the serial used.

    Idempotent — re-running upserts the same row.
    """
    serial = serial or f"e2e-verified-{user_id[:8]}"
    query(
        "INSERT INTO meter_read_model "
        "  (serial_number, meter_id, user_id, zone_id, status, is_verified, updated_at) "
        f"VALUES ('{serial}', gen_random_uuid(), '{user_id}', NULL, 'active', true, now()) "
        "ON CONFLICT (serial_number) DO UPDATE SET "
        "  user_id = EXCLUDED.user_id, is_verified = true, updated_at = now();",
        db=PG_DB_TRADING,
    )
    return serial


# The dev platform payer (`SOLANA_PAYER_KEY` default in the root .env). It holds
# the THBC currency inventory on the dev chain, so it is the one wallet a test
# can rely on being funded across chain-resets (init re-mints to it).
FUNDED_WALLET = os.getenv(
    "E2E_FUNDED_WALLET", "EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ"
)


def grant_funded_wallet(user_id: str, wallet: str | None = None) -> str:
    """Point `user_id`'s primary wallet at one that holds currency on-chain, so
    Trading's buy-side funding gate admits their bids.

    Trading refuses a buy (402) when the buyer's currency balance cannot cover
    the order's maximum spend, and it resolves the buyer's wallet from its own
    `iam_wallet_read_model` mirror. A suite that only exercises the CDA has no
    business standing up THBC issuance just to place a bid, so this repoints the
    mirror at the funded dev payer — the same backdoor class as
    `grant_verified_meter` (seed only what the gate reads; the gate's balance
    check itself still runs against the real chain).

    Idempotent — re-running upserts the same primary row.
    """
    wallet = wallet or FUNDED_WALLET
    query(
        f"UPDATE iam_wallet_read_model SET is_primary = false WHERE user_id = '{user_id}';",
        db=PG_DB_TRADING,
    )
    query(
        "INSERT INTO iam_wallet_read_model "
        "  (user_id, wallet_address, is_primary, blockchain_registered, updated_at) "
        f"VALUES ('{user_id}', '{wallet}', true, true, now()) "
        "ON CONFLICT (user_id, wallet_address) DO UPDATE SET "
        "  is_primary = true, updated_at = now();",
        db=PG_DB_TRADING,
    )
    return wallet


_BUYERS_FUNDED: set[str] = set()


def ensure_funded(user_id) -> None:
    """Best-effort, once-per-user wrapper around `grant_funded_wallet`.

    Call before placing a buy order from a suite that is not itself testing
    wallet funding. Never raises: if the backdoor is unavailable, the buy is
    attempted anyway and the test's own assertion reports the resulting 402 —
    which is more informative than an error from this helper.
    """
    key = str(user_id)
    if key in _BUYERS_FUNDED:
        return
    try:
        grant_funded_wallet(key)
    except Exception as e:  # noqa: BLE001 — a backdoor failure must not mask the test
        print(f"warning: could not point {key} at a funded wallet for buying: {e}")
    _BUYERS_FUNDED.add(key)


_SELLERS_GRANTED: set[str] = set()


def ensure_sellable(user_id) -> None:
    """Best-effort, once-per-user wrapper around `grant_verified_meter`.

    Call before placing a sell order from a suite that is not itself testing meter
    onboarding. Never raises: if the backdoor is unavailable (no docker/psql), the
    sell is attempted anyway and the test's own assertion reports the resulting
    403 — which is more informative than an error from this helper.
    """
    key = str(user_id)
    if key in _SELLERS_GRANTED:
        return
    try:
        grant_verified_meter(key)
    except Exception as e:  # noqa: BLE001 — a backdoor failure must not mask the test
        print(f"warning: could not grant {key} a verified meter for selling: {e}")
    _SELLERS_GRANTED.add(key)


def user_ows_wallet_id(username: str) -> str:
    return scalar(f"SELECT ows_wallet_id FROM users WHERE username = '{username}';",
                  db=db_for("users"))


def truncate_test_data():
    """Remove e2e-created rows. Extend per-table as suites grow.
    Safe: only deletes rows with e2e markers (username/email prefixes)."""
    query("DELETE FROM users WHERE username LIKE 'e2e_%' OR email LIKE '%@grx.test';",
          db=db_for("users"))
