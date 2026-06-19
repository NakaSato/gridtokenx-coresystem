"""Suite 20 — Aggregator Bridge ingest VARIANTS (previously uncovered endpoints).

`test_telemetry.py` covers the single signed REST ingest + single gRPC Ingest.
This file fills the gaps for the remaining ingest surfaces wired in
`gridtokenx-aggregator-bridge/src/main.rs:613-628` (REST routes) and
`crates/aggregator-protocol/proto/oracle.proto:11` (gRPC IngestBatch):

  1. POST /v1/private-network/ingest/batch  (signed DLMS batch)
     handler: handlers.rs:363 ingest_private_network_batch
              body  = BatchPrivateNetworkPayload { protocol, readings: [obj,...] }
                      (models.rs:98) — NOTE each reading object is FLAT (fields at
                      top level, NOT nested under a `payload` key like the single
                      endpoint). Per-reading sign target is the same canonical
                      {device_id}:{kwh}:{timestamp_ms} (handlers.rs:430,86 +
                      verify_rest_signature) — kwh resolved by canonical_sign_value
                      (handlers.rs:46). Response = Vec<IngestResponse>
                      (models.rs:108: {status, reading_id, device_type, stream}),
                      FILTERED to accepted readings only (handlers.rs:508).

  2. POST /v1/ingest/telemetry  +  /v1/ingest/telemetry/batch  (legacy)
     Both routes map to the SAME handler ingest_legacy_batch (main.rs:622-628,
     handlers.rs:294). Body = { readings: [obj,...] } where each obj has
     meter_serial|meter_id, kwh, timestamp(RFC3339), energy_generated/consumed,
     zone_code. NO signature verification on this path — every reading is
     disseminated and returned (handlers.rs:300-360). Response = Vec<IngestResponse>
     (one per reading, unfiltered). Missing `readings` => 400.

  3. OracleService/IngestBatch gRPC  (oracle.proto:11, service.rs:405)
     Request = MeterReadingBatchRequest { readings: [MeterReading,...] }.
     Per-reading sign target = "{meter_id}:{kwh}:{timestamp}" using the kwh STRING
     on the wire as-is (service.rs:456) — sign over the same canonicalized kwh sent.
     Response = MeterReadingBatchResponse { receipt_ids, status, accepted_count,
     rejected_count } (proto:62, service.rs:521). status="all_accepted" when
     rejected_count==0 else "partially_accepted" (service.rs:524). A reading with no
     signature is rejected (fail-closed, service.rs:470) unless
     AGGREGATOR_ALLOW_UNVERIFIED_TELEMETRY=true.

  4. GET /metrics  (Prometheus; main.rs:637-643, MetricsHandle::render)
     Open route (no API key). Trivial: 200 + Prometheus text body containing an
     aggregator_* metric. `aggregator_grid_frequency_hz` (a gauge set in
     src/main.rs:391) is present in steady state; we assert the `aggregator_`
     prefix to stay robust if that single gauge is ever renamed.

Conventions mirror test_telemetry.py exactly: Ed25519 via lib/crypto.py, device
pubkey registered in Redis (lib/redis_util.py), skip-if-unreachable guards, the
same harness API key. No shared lib/* or env.sh files are edited.

Run: cd tests/e2e && uv run --no-project python -m pytest 20_oracle/test_ingest_variants.py -v
"""
import datetime
import os
import time

import pytest
import requests

import crypto
import redis_util

ORACLE_REST = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
ORACLE_GRPC = os.getenv("AGGREGATOR_BRIDGE_GRPC", "localhost:5030")
BATCH_URL = f"{ORACLE_REST}/v1/private-network/ingest/batch"
LEGACY_URL = f"{ORACLE_REST}/v1/ingest/telemetry"
LEGACY_BATCH_URL = f"{ORACLE_REST}/v1/ingest/telemetry/batch"
METRICS_URL = f"{ORACLE_REST}/metrics"
# Same accepted harness key as test_telemetry.py (legacy `e2e-test-key` -> 401).
API_KEY = os.getenv("AGGREGATOR_API_KEY", "engineering-department-api-key-2025")
HEADERS = {"X-API-KEY": API_KEY}


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
    """Registered Ed25519 device. Returns dict(meter_id, priv, pub_hex)."""
    pk, pub_hex = crypto.new_identity()
    meter_id = f"E2E-BATCH-{int(time.time() * 1000) % 1000000}"
    redis_util.register_device_key(meter_id, pub_hex)
    redis_util.register_meter(meter_id, "00000000-0000-0000-0000-000000000001")
    yield {"meter_id": meter_id, "priv": pk, "pub_hex": pub_hex}
    redis_util.unregister_device(meter_id)


def _iso(ts_ms: int) -> str:
    dt = datetime.datetime.fromtimestamp(ts_ms / 1000, tz=datetime.timezone.utc)
    return dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _signed_batch_reading(meter_id, kwh, ts_ms, signature):
    """One element of BatchPrivateNetworkPayload.readings — a FLAT reading object
    (handlers.rs:363,396 reads device_id/signature/kwh/timestamp at the top level,
    unlike the single endpoint which nests them under `payload`)."""
    return {
        "device_id": meter_id,
        "kwh": float(kwh),
        "timestamp": _iso(ts_ms),
        "signature": signature,
    }


# ---------------------------------------------------------------------------
# 1. REST signed batch — POST /v1/private-network/ingest/batch
# ---------------------------------------------------------------------------

def test_rest_batch_all_valid_accepted(device):
    """A batch of correctly signed readings is accepted; every reading is
    disseminated, so the response array length == batch size (filtered to accepted,
    handlers.rs:508)."""
    base_ts = int(time.time() * 1000)
    readings = []
    for i in range(3):
        kwh = f"{100 + i}.{i}{i}"  # distinct values
        ts = base_ts + i  # distinct timestamps
        sig = crypto.sign_telemetry(device["priv"], device["meter_id"], kwh, ts)
        readings.append(_signed_batch_reading(device["meter_id"], kwh, ts, sig))

    body = {"protocol": "dlms", "readings": readings}
    r = requests.post(BATCH_URL, json=body, headers=HEADERS, timeout=10)
    assert r.status_code in (200, 202), f"valid batch rejected: {r.status_code} {r.text}"
    arr = r.json()
    assert isinstance(arr, list), f"batch response not a list: {arr}"
    assert len(arr) == len(readings), (
        f"expected {len(readings)} accepted readings, got {len(arr)}: {arr}"
    )
    # Each accepted reading carries the IngestResponse shape (models.rs:108).
    for item in arr:
        assert item.get("status") == "accepted", f"unexpected status: {item}"
        assert item.get("reading_id"), f"missing reading_id: {item}"
        assert item.get("stream"), f"missing stream: {item}"


def test_rest_batch_invalid_signature_filtered(device):
    """Fail-closed: in a mixed batch the tampered reading is DROPPED (not 2xx-blocked
    for the whole batch) — response contains only the valid reading
    (handlers.rs:448-451 returns None for invalid)."""
    base_ts = int(time.time() * 1000)
    good_kwh, good_ts = "55.5", base_ts
    good_sig = crypto.sign_telemetry(device["priv"], device["meter_id"], good_kwh, good_ts)
    good = _signed_batch_reading(device["meter_id"], good_kwh, good_ts, good_sig)
    bad = _signed_batch_reading(device["meter_id"], "66.6", base_ts + 1, "invalid_signature_base58")

    body = {"protocol": "dlms", "readings": [good, bad]}
    r = requests.post(BATCH_URL, json=body, headers=HEADERS, timeout=10)
    assert r.status_code in (200, 202), f"mixed batch rejected: {r.status_code} {r.text}"
    arr = r.json()
    assert isinstance(arr, list), f"batch response not a list: {arr}"
    # Only the valid reading survives the fail-closed filter.
    assert len(arr) == 1, f"expected exactly 1 accepted reading (bad filtered), got {len(arr)}: {arr}"


def test_rest_batch_disseminated(device):
    """An accepted batch reading reaches a zone Redis Stream (dissemination
    fan-out), same assertion as the single-ingest Case 5."""
    before = redis_util.stream_total_len()
    ts = int(time.time() * 1000)
    kwh = "321.0"
    sig = crypto.sign_telemetry(device["priv"], device["meter_id"], kwh, ts)
    body = {"protocol": "dlms", "readings": [_signed_batch_reading(device["meter_id"], kwh, ts, sig)]}
    r = requests.post(BATCH_URL, json=body, headers=HEADERS, timeout=10)
    assert r.status_code in (200, 202), f"batch rejected: {r.status_code} {r.text}"

    deadline = time.time() + 10
    grew = False
    while time.time() < deadline:
        try:
            if redis_util.stream_total_len() > before:
                grew = True
                break
        except Exception:
            pass
        time.sleep(0.5)
    assert grew, "no zone stream growth after accepted batch reading (dissemination failed)"


# ---------------------------------------------------------------------------
# 2. Legacy ingest — /v1/ingest/telemetry and /v1/ingest/telemetry/batch
#    (both routes -> ingest_legacy_batch; NO signature verification)
# ---------------------------------------------------------------------------

def _legacy_reading(meter_id, *, kwh, ts_ms, generated=None, consumed=None):
    """One element of the legacy `readings` array (handlers.rs:312-340). meter_serial
    is the primary id key; energy_* default to kwh/0 when absent."""
    obj = {
        "meter_serial": meter_id,
        "kwh": float(kwh),
        "timestamp": _iso(ts_ms),
    }
    if generated is not None:
        obj["energy_generated"] = float(generated)
    if consumed is not None:
        obj["energy_consumed"] = float(consumed)
    return obj


@pytest.mark.parametrize("url", [LEGACY_URL, LEGACY_BATCH_URL])
def test_legacy_ingest_accepts_unsigned_batch(device, url):
    """Legacy endpoints take an UNSIGNED `{readings:[...]}` batch and return one
    IngestResponse per reading (handlers.rs:294-360 — no sig check). Both
    /v1/ingest/telemetry and /v1/ingest/telemetry/batch hit the same handler
    (main.rs:622-628), so both must behave identically."""
    base_ts = int(time.time() * 1000)
    readings = [
        _legacy_reading(device["meter_id"], kwh="10.5", ts_ms=base_ts, generated=10.5, consumed=0.0),
        _legacy_reading(device["meter_id"], kwh="20.0", ts_ms=base_ts + 1, generated=20.0, consumed=0.0),
    ]
    r = requests.post(url, json={"readings": readings}, headers=HEADERS, timeout=10)
    assert r.status_code in (200, 202), f"legacy ingest rejected at {url}: {r.status_code} {r.text}"
    arr = r.json()
    assert isinstance(arr, list), f"legacy response not a list: {arr}"
    assert len(arr) == len(readings), (
        f"legacy: expected {len(readings)} responses, got {len(arr)}: {arr}"
    )
    for item in arr:
        assert item.get("status") == "accepted", f"unexpected legacy status: {item}"
        assert item.get("reading_id"), f"missing reading_id: {item}"


def test_legacy_ingest_missing_readings_is_400(device):
    """No `readings` array => 400 Bad Request (handlers.rs:300-303)."""
    r = requests.post(LEGACY_URL, json={"not_readings": []}, headers=HEADERS, timeout=5)
    assert r.status_code == 400, f"expected 400 for missing readings, got {r.status_code} {r.text}"


# ---------------------------------------------------------------------------
# 3. gRPC OracleService/IngestBatch
# ---------------------------------------------------------------------------

def test_grpc_ingest_batch(device):
    """gRPC IngestBatch accepts a batch of signed readings and reports an accurate
    accepted/rejected split (service.rs:405,521). Mixed batch: one valid + one
    tampered => accepted_count==1, rejected_count==1, status=partially_accepted."""
    grpc = pytest.importorskip("grpc")
    try:
        import oracle_pb2
        import oracle_pb2_grpc
    except ImportError:
        pytest.skip("oracle proto stubs not on path")

    channel = grpc.insecure_channel(ORACLE_GRPC)
    stub = oracle_pb2_grpc.OracleServiceStub(channel)

    meter = device["meter_id"]
    base_ts = int(time.time() * 1000)

    # Valid reading. Wire kwh must equal the canonicalized form we sign over
    # (service.rs:456 uses the wire string verbatim in the sign target).
    good_kwh, good_ts = "44.4", base_ts
    good_kwh_canon = crypto.rust_f64_str(good_kwh)
    good_sig = crypto.sign_telemetry(device["priv"], meter, good_kwh, good_ts)
    good = oracle_pb2.MeterReading(
        meter_id=meter, kwh=good_kwh_canon, timestamp=good_ts, signature=good_sig,
    )

    # Tampered reading — same meter, bogus signature => fail-closed reject.
    bad_kwh, bad_ts = "55.5", base_ts + 1
    bad = oracle_pb2.MeterReading(
        meter_id=meter, kwh=crypto.rust_f64_str(bad_kwh), timestamp=bad_ts,
        signature="invalid_signature_base58",
    )

    req = oracle_pb2.MeterReadingBatchRequest(readings=[good, bad])
    try:
        resp = stub.IngestBatch(req, timeout=10)
    except grpc.RpcError as e:
        if e.code() == grpc.StatusCode.UNAVAILABLE:
            pytest.skip(f"Oracle gRPC {ORACLE_GRPC} unreachable (server not bound): {e.details()}")
        pytest.fail(f"gRPC IngestBatch failed: {e.code()} {e.details()}")

    assert resp.accepted_count == 1, f"expected 1 accepted, got {resp.accepted_count} (resp={resp})"
    assert resp.rejected_count == 1, f"expected 1 rejected, got {resp.rejected_count} (resp={resp})"
    assert resp.status == "partially_accepted", f"unexpected status: {resp.status!r}"
    assert len(resp.receipt_ids) == 1, f"expected 1 receipt id, got {resp.receipt_ids}"


# ---------------------------------------------------------------------------
# 4. GET /metrics — Prometheus
# ---------------------------------------------------------------------------

def test_metrics_endpoint_exposes_prometheus():
    """/metrics is open (no API key) and returns Prometheus text with an
    aggregator_* metric (main.rs:637-643)."""
    r = requests.get(METRICS_URL, timeout=5)  # intentionally no API key header
    assert r.status_code == 200, f"/metrics not 200: {r.status_code} {r.text[:200]}"
    body = r.text
    assert "aggregator_" in body, (
        f"no aggregator_* metric in /metrics output (got {len(body)} bytes): {body[:200]!r}"
    )
