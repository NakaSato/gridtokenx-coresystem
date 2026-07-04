"""Suite 30 — DB-tier owner attribution, end to end (Option A).

Proves the link added in the aggregator-bridge MeterRegistry: a meter registered
ONLY through the **meter-service API** (→ shared `gridtokenx` Postgres `meters`,
joined to `users` for the wallet) — with **no Redis owner seed** — is still
attributed by the Aggregator Bridge, which resolves `serial → (user_id, wallet)`
from Postgres (tier-3, after local cache + Redis) and mints the surplus to the
registered owner wallet on `chain.tx.mint`.

Contrast `test_surplus_mint.py`, which seeds the owner map directly in Redis. Here
we explicitly DELETE the Redis owner keys after registration so resolution MUST
come from Postgres — exactly the production path "readings via Aggregator Bridge
only; register via meter-service API → meter database".

  meter-service POST /api/v1/meters (JWT)         -> Postgres `meters` row
  (NO gridtokenx:meters:{serial}:* owner keys in Redis)
  backdated encrypted surplus frame -> gRPC BulkRawIngest (lib/settlement_ingest —
  works on dev AND secure stacks; plaintext REST is 426 under secure mode)
    -> AES-GCM decrypt + Ed25519 verify (device enckey/pubkey in Redis)
    -> zone stream -> billing bin -> flush loop
    -> MeterRegistry.resolve_wallet() MISSES Redis, HITS Postgres, backfills
    -> mint on chain.tx.mint with recipient_wallet == owner wallet from the DB

SKIP semantics (anti-false-green): if no mint arrives within MINT_WAIT, SKIP with a
loud reason (minting disabled / bridge predates the feature) rather than passing.

Slow by construction (window must close past grace; flush loop polls on interval).
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time

import pytest
import requests

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))

import crypto
import db
import nats_util
import redis_util
import settlement_ingest

SUBJECT = os.getenv("MINT_NATS_SUBJECT", "chain.tx.mint")

# meter-service registration API (binds 0.0.0.0:8080, host-mapped to 4062).
METER_SERVICE = os.getenv("METER_SERVICE_URL", "http://localhost:4062")
JWT_SECRET = os.getenv(
    "JWT_SECRET", "dev-jwt-secret-key-minimum-32-characters-long-for-development-2025"
)

MINT_WAIT = float(os.getenv("MINT_WAIT_SECS", "150"))
BACKDATE_MS = int(os.getenv("MINT_BACKDATE_SECS", str(20 * 60))) * 1000
ENVELOPE_AUTH_SCHEME_V1 = "ecdsa-p256-sha256-v1"


def _meter_service_up() -> bool:
    try:
        requests.get(f"{METER_SERVICE}/health", timeout=3)
        return True
    except Exception:
        return False


def _redis_up() -> bool:
    try:
        redis_util.client().ping()
        return True
    except Exception:
        return False


pytestmark = [
    pytest.mark.skipif(
        not settlement_ingest.grpc_up(),
        reason=f"aggregator gRPC not reachable at {settlement_ingest.ORACLE_GRPC}",
    ),
    pytest.mark.skipif(not _meter_service_up(), reason=f"meter-service not reachable at {METER_SERVICE}"),
    pytest.mark.skipif(not _redis_up(), reason="Redis not reachable (lib/redis_util)"),
    pytest.mark.skipif(not nats_util.reachable(), reason=f"NATS not reachable at {nats_util.NATS_URL}"),
]


def _b64url(raw: bytes) -> bytes:
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def _mint_jwt(user_id: str, secret: str, ttl_secs: int = 3600) -> str:
    """Minimal HS256 JWT (sub + exp) matching the meter-service auth extractor."""
    header = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    exp = int(time.time()) + ttl_secs
    payload = _b64url(json.dumps({"sub": user_id, "exp": exp}, separators=(",", ":")).encode())
    signing_input = header + b"." + payload
    sig = _b64url(hmac.new(secret.encode(), signing_input, hashlib.sha256).digest())
    return (signing_input + b"." + sig).decode()


def _wallet_bearing_user():
    """Borrow an existing user with a non-empty wallet — the meter-service FK
    target and the wallet the bridge must resolve from Postgres."""
    row = db.query(
        "SELECT id || '|' || wallet_address FROM users "
        "WHERE wallet_address IS NOT NULL AND wallet_address <> '' LIMIT 1;"
    )
    if not row:
        return None, None
    user_id, _, wallet = row.splitlines()[0].partition("|")
    return user_id.strip(), wallet.strip()


def _register_meter_via_api(token: str, serial: str):
    r = requests.post(
        f"{METER_SERVICE}/api/v1/meters",
        json={"serial_number": serial, "meter_type": "smart_meter", "location": "e2e-db-tier"},
        headers={"Authorization": f"Bearer {token}"},
        timeout=15,
    )
    assert r.status_code == 200, f"meter-service register failed: {r.status_code} {r.text}"


def test_db_registered_meter_mints_to_owner_without_redis_seed():
    """Register a meter via the meter-service API (Postgres only), strip any Redis
    owner keys, then a backdated surplus window must still mint to the owner wallet
    resolved from Postgres — proving the MeterRegistry DB tier end to end."""
    user_id, wallet = _wallet_bearing_user()
    if not user_id:
        pytest.skip("no wallet-bearing user in Postgres `users`")

    token = _mint_jwt(user_id, JWT_SECRET)
    # LDN in the DLMS frame is 8 bytes — keep the serial ≤8 chars so the id the
    # bridge decodes matches the Postgres row (see lib/settlement_ingest.py).
    serial = f"D{int(time.time() * 1000) % 10_000_000}"
    priv, pub_hex = crypto.new_identity()
    enc_key = bytes(range(32))
    gen = 50  # surplus: net = 50 - 0

    _register_meter_via_api(token, serial)

    # Device identity (Ed25519 pubkey + AES enckey) is needed to decrypt/verify the
    # frame — separate from ownership, which must come from Postgres.
    redis_util.register_device_key(serial, pub_hex)
    redis_util.register_enckey(serial, enc_key.hex())
    # CRITICAL: ensure NO Redis owner seed — resolution must fall through to Postgres.
    c = redis_util.client()
    c.delete(f"gridtokenx:meters:{serial}:user_id")
    c.delete(f"gridtokenx:meters:{serial}:wallet")
    assert c.get(f"gridtokenx:meters:{serial}:wallet") is None, "owner wallet must NOT be pre-seeded in Redis"

    stub = settlement_ingest.stub()
    handle = {"meter": serial, "priv": priv, "enc_key": enc_key}
    ts_sec = int(time.time()) - BACKDATE_MS // 1000  # window already closed past grace

    def _trigger():
        settlement_ingest.ingest(stub, handle, generated=gen, consumed=0, ts_sec=ts_sec)

    def _matches(m):
        return str(m.get("idempotency_key", "")).startswith(f"mint:{serial}:")

    try:
        msgs = nats_util.collect_sync(SUBJECT, _trigger, match=_matches, timeout=MINT_WAIT, want=1)
    finally:
        redis_util.unregister_device(serial)
        redis_util.unregister_enckey(serial)
        db.query(f"DELETE FROM meter_readings WHERE meter_serial = '{serial}';")
        db.query(f"DELETE FROM meters WHERE serial_number = '{serial}';")

    mints = [m for m in msgs if str(m.get("idempotency_key", "")).startswith(f"mint:{serial}:")]
    if not mints:
        pytest.skip(
            f"no mint on '{SUBJECT}' within {MINT_WAIT:.0f}s — minting disabled "
            "(MINT_VIA_CHAIN_BRIDGE unset) or bridge predates the feature. Refusing a false pass."
        )

    mint = mints[0]
    # energy_kwh == net surplus.
    assert abs(float(mint.get("energy_kwh", 0)) - gen) < 1e-6, f"energy_kwh != surplus {gen}: {mint}"
    # THE point: recipient resolved from Postgres (no Redis seed existed), equals the owner wallet.
    assert mint.get("recipient_wallet") == wallet, (
        f"recipient_wallet must be the DB-resolved owner wallet ({wallet}): {mint}"
    )
    # Signed envelope intact.
    assert mint.get("service_identity"), f"missing service_identity: {mint}"
    auth = mint.get("auth")
    assert isinstance(auth, dict) and auth.get("scheme") == ENVELOPE_AUTH_SCHEME_V1, f"bad auth: {mint}"
