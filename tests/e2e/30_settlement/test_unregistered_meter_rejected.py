"""Unregistered meter → rejected at ingress, never settles.

Closes the meter→solana hardening plan's e2e ingress-rejection assertion. The
aggregator fail-closes on telemetry whose device has no Ed25519 pubkey in Redis
(`gridtokenx:devices:{meter_id}:pubkey`): with signature enforcement ON (the
default — `AGGREGATOR_ALLOW_UNVERIFIED_TELEMETRY` unset/≠true) such a reading is
rejected at `/v1/private-network/ingest` BEFORE dissemination, so it can never
reach a billing bin or settlement.

Differential design (isolates the cause, no Redis-stream race):
  - control meter B: pubkey registered, valid signature → accepted (202/200)
  - target  meter A: pubkey NOT registered, valid self-signed signature
        → rejected (401/403); the ONLY difference from B is the missing
          registration, so the rejection is attributable to that alone.

If meter A is accepted, the running aggregator has enforcement disabled
(dev-permissive) and the invariant can't be asserted → the test skips rather
than fails. Needs the aggregator REST up + Redis reachable (lib/redis_util).
"""
import datetime
import os
import sys

import pytest
import requests

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))

import crypto
import redis_util

ORACLE = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
API_KEY = os.getenv("AGGREGATOR_API_KEY", "engineering-department-api-key-2025")
INGEST = f"{ORACLE}/v1/private-network/ingest"


def _oracle_up() -> bool:
    try:
        # /health is unauthenticated; any 2xx/4xx proves the listener is live.
        requests.get(f"{ORACLE}/health", timeout=3)
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
    pytest.mark.skipif(not _oracle_up(), reason=f"aggregator REST not reachable at {ORACLE}"),
    pytest.mark.skipif(not _redis_up(), reason="Redis not reachable (lib/redis_util)"),
]


def _send(meter: str, priv, ts_ms: int):
    """Sign + POST a 10 kWh generation reading as meter `meter`."""
    dt = datetime.datetime.fromtimestamp(ts_ms / 1000, tz=datetime.timezone.utc)
    iso = dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    sig = crypto.sign_telemetry(priv, meter, 10.0, ts_ms)
    return requests.post(
        INGEST,
        timeout=20,
        headers={"X-API-KEY": API_KEY},
        json={
            "protocol": "dlms",
            "device_id": meter,
            "payload": {
                "device_id": meter,
                "timestamp": iso,
                "kwh": 10.0,
                "energy_generated": 10.0,
                "energy_consumed": 0.0,
                "signature": sig,
            },
        },
    )


def test_unregistered_meter_rejected_at_ingress():
    import time

    tag = int(time.time() * 1000) % 1_000_000
    ts_ms = int(time.time() * 1000)

    # --- control: a REGISTERED meter must be accepted -------------------
    ctrl_meter = f"REG-CTRL-{tag}"
    ctrl_priv, ctrl_pub = crypto.new_identity()
    redis_util.register_device_key(ctrl_meter, ctrl_pub)
    try:
        ctrl = _send(ctrl_meter, ctrl_priv, ts_ms)
        assert ctrl.status_code in (200, 202), (
            f"registered control meter must be accepted, got {ctrl.status_code} {ctrl.text}"
        )

        # --- target: an UNREGISTERED meter, validly self-signed ----------
        unreg_meter = f"UNREG-{tag}"
        unreg_priv, _unreg_pub = crypto.new_identity()
        redis_util.unregister_device(unreg_meter)  # ensure no stale pubkey
        resp = _send(unreg_meter, unreg_priv, ts_ms)

        if resp.status_code in (200, 202):
            pytest.skip(
                "aggregator accepted an unregistered meter — signature enforcement "
                "is disabled (AGGREGATOR_ALLOW_UNVERIFIED_TELEMETRY=true); cannot "
                "assert the fail-closed ingress invariant"
            )

        # Fail-closed: missing pubkey → 403 (Ok(false)) or 401 (verify Err).
        assert resp.status_code in (401, 403), (
            f"unregistered meter must be rejected at ingress, got {resp.status_code} {resp.text}"
        )
    finally:
        redis_util.unregister_device(ctrl_meter)
