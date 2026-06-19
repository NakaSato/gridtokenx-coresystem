"""Suite 20 — Simulator → Aggregator OBIS-payload contract (REST DLMS, Path A).

`test_telemetry.py` ingests a MINIMAL hand-rolled JSON (`energy_consumed` only),
so it never exercises the OBIS-code decode path. The real producer
(`gridtokenx-smartmeter-simulator/.../transport/aggregator_bridge.py::_build_obis_payload`)
ships an IEC-62056 **OBIS-coded** frame: active import/export in **Wh** under codes
`1.1.1.8.0.255` / `1.1.2.8.0.255`, plus convenience `kwh`/`energy_*` fields. This
test pins that producer↔decoder contract end-to-end:

  simulator-shaped OBIS JSON  →  /v1/private-network/ingest (protocol="dlms")
    →  DlmsStack.map_payload (Wh→kWh, OBIS precedence)  →  Redis dissemination

It mirrors the simulator's payload (the package isn't import-able from the e2e venv
— missing `base58` etc.), citing the source so drift is caught by review. Two
invariants the minimal-payload test cannot see:

  1. **Wh→kWh decode**: OBIS export 5000 Wh → disseminated `generated_kwh == 5.0`
     (`dlms.rs map_payload:74-77,168`).
  2. **OBIS precedence**: when BOTH an OBIS register AND a plain `energy_*` key are
     present, the OBIS value wins (`dlms.rs:56-64,157-166`). We send a DECOY plain
     `energy_generated` that disagrees with the OBIS export and assert the OBIS
     value is the one disseminated — a precedence regression (last-write-wins on the
     random HashMap order) would flip this.

Sign-target is `kwh` (the net value) — `canonical_sign_value` resolves `kwh` first
(aggregator CLAUDE.md / handlers.rs), matching the simulator's
`canonical = f"{meter_id}:{kwh_str}:{timestamp_ms}"`.

Run: cd tests/e2e && python -m pytest 20_oracle/test_simulator_obis_contract.py -v
Skips gracefully if Oracle / Redis are unreachable.
"""
import datetime
import os
import time

import pytest
import requests

import crypto
import redis_util

ORACLE_REST = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
INGEST_URL = f"{ORACLE_REST}/v1/private-network/ingest"
# Ingest auth is validated via IAM (aggregator_api::auth); the accepted harness key is the
# simulator's SMARTMETER_AGGREGATOR_API_KEY (legacy `e2e-test-key` is rejected 401). The real
# simulator sends the same header (aggregator_bridge.py:174-176).
API_KEY = os.getenv("AGGREGATOR_API_KEY", "engineering-department-api-key-2025")
HEADERS = {"X-API-KEY": API_KEY}

# OBIS codes the simulator emits and DlmsStack consumes (aggregator_bridge.py:47-49,
# dlms.rs obis::ELEC_ACTIVE_{IMPORT,EXPORT}_TOTAL).
OBIS_ACTIVE_IMPORT = "1.1.1.8.0.255"  # consumed, Wh
OBIS_ACTIVE_EXPORT = "1.1.2.8.0.255"  # generated, Wh


def _oracle_up() -> bool:
    try:
        requests.get(f"{ORACLE_REST}/health", timeout=3)
        return True
    except Exception:
        return False


def _redis_up() -> bool:
    try:
        redis_util.client().ping()
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(
    not (_oracle_up() and _redis_up()),
    reason="Oracle Bridge REST or Redis unreachable",
)


@pytest.fixture
def device():
    pk, pub_hex = crypto.new_identity()
    meter_id = f"E2E-OBIS-{int(time.time() * 1000) % 1000000}"
    redis_util.register_device_key(meter_id, pub_hex)
    redis_util.register_meter(meter_id, "00000000-0000-0000-0000-000000000001")
    yield {"meter_id": meter_id, "priv": pk, "pub_hex": pub_hex}
    redis_util.unregister_device(meter_id)


def _obis_payload(meter_id, *, export_wh, import_wh, decoy_generated_kwh, signature, ts_iso):
    """Simulator-shaped OBIS frame (mirror of _build_obis_payload). The plain
    `energy_generated` is a DECOY that disagrees with the OBIS export so the
    assertion proves OBIS precedence, not coincidence. Timestamp is RFC-3339 ISO
    (the handler parses `timestamp`, not a `_ms` int — handlers.rs:171)."""
    return {
        "protocol": "dlms",
        "device_id": meter_id,
        "payload": {
            "device_id": meter_id,
            OBIS_ACTIVE_IMPORT: float(import_wh),
            OBIS_ACTIVE_EXPORT: float(export_wh),
            # Convenience fields the handler also reads. `kwh` (net) is the
            # sign-target; `energy_generated` is the decoy that must LOSE to OBIS.
            "kwh": (export_wh - import_wh) / 1000.0,
            "energy_generated": float(decoy_generated_kwh),
            "energy_consumed": import_wh / 1000.0,
            "timestamp": ts_iso,
            "signature": signature,
        },
    }


def test_simulator_obis_frame_accepted_and_decoded(device):
    """Wh→kWh decode + OBIS precedence over a decoy plain key, end-to-end."""
    export_wh, import_wh = 5000, 2000
    net_kwh = (export_wh - import_wh) / 1000.0  # 3.0 — the signed value
    # Whole-second timestamp (no sub-second), matching the simulator: it signs
    # ts_ms = whole_seconds * 1000 and the handler derives ms from the ISO string.
    sec = int(time.time())
    ts_iso = datetime.datetime.fromtimestamp(sec, tz=datetime.timezone.utc).isoformat()
    ts_ms = sec * 1000
    sig = crypto.sign_telemetry(device["priv"], device["meter_id"], net_kwh, ts_ms)
    body = _obis_payload(
        device["meter_id"],
        export_wh=export_wh,
        import_wh=import_wh,
        decoy_generated_kwh=999.0,  # disagrees with OBIS export (5.0) — must lose
        signature=sig,
        ts_iso=ts_iso,
    )

    r = requests.post(INGEST_URL, json=body, headers=HEADERS, timeout=5)
    assert r.status_code in (200, 202), f"OBIS reading rejected: {r.status_code} {r.text}"

    # Poll dissemination for the decoded reading.
    reading = None
    for _ in range(20):
        reading = redis_util.find_disseminated_reading(device["meter_id"])
        if reading is not None:
            break
        time.sleep(0.25)
    assert reading is not None, "OBIS reading was not disseminated to any zone stream"

    metrics = reading.get("metrics", {})
    assert metrics.get("type") == "energy", f"unexpected metrics: {metrics}"
    # OBIS export 5000 Wh → 5.0 kWh, NOT the decoy 999.0 → OBIS precedence + Wh scaling.
    assert metrics.get("generated_kwh") == pytest.approx(5.0), (
        f"expected OBIS-derived generated 5.0 kWh (decoy was 999); got {metrics}"
    )
    assert metrics.get("consumed_kwh") == pytest.approx(2.0), (
        f"expected OBIS-derived consumed 2.0 kWh; got {metrics}"
    )
    assert metrics.get("net_kwh") == pytest.approx(3.0), (
        f"expected net 3.0 kWh; got {metrics}"
    )
