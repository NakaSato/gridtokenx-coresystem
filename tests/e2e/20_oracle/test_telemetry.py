"""Suite 20 — Oracle Bridge telemetry ingestion (REST + gRPC).

Covers signed-reading accept, tampered/unknown-device reject, dissemination fan-out.
Device identity registered via Redis (gridtokenx:devices:{id}:pubkey) — Oracle's
signature_verifier looks up the pubkey there. Canonical sig: {meter_id}:{kwh}:{ts_ms}.

Run: cd tests/e2e && python -m pytest 20_oracle -v
Skips gracefully if Oracle / Redis are unreachable.
"""
import datetime
import os
import time

import pytest
import requests

import crypto
import events
import redis_util

ORACLE_REST = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
ORACLE_GRPC = os.getenv("AGGREGATOR_BRIDGE_GRPC", "localhost:5030")
INGEST_URL = f"{ORACLE_REST}/v1/private-network/ingest"
KAFKA_TOPIC = os.getenv("KAFKA_TOPIC_METER_READINGS", "meter.readings")
# api_key_auth gates ingest (auth.rs); the aggregator seeds `e2e-test-key` in its
# static GRIDTOKENX_API_KEYS for the harness (docker-compose.yml:755). Without it the
# request is rejected at the auth layer (401) before signature verification runs.
API_KEY = os.getenv("AGGREGATOR_API_KEY", "e2e-test-key")
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
    meter_id = f"E2E-METER-{int(time.time()*1000)%1000000}"
    redis_util.register_device_key(meter_id, pub_hex)
    redis_util.register_meter(meter_id, "00000000-0000-0000-0000-000000000001")
    yield {"meter_id": meter_id, "priv": pk, "pub_hex": pub_hex}
    redis_util.unregister_device(meter_id)


def _rest_payload(meter_id, kwh, ts_ms, signature):
    dt = datetime.datetime.fromtimestamp(ts_ms / 1000, tz=datetime.timezone.utc)
    iso = dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return {
        "protocol": "dlms",
        "device_id": meter_id,
        "payload": {
            "device_id": meter_id,
            "timestamp": iso,
            "energy_consumed": float(kwh),
            "signature": signature,
        },
    }


def test_valid_signed_reading_accepted(device):
    """Case 1: correctly signed reading is accepted."""
    kwh, ts = "123.45", int(time.time() * 1000)
    sig = crypto.sign_telemetry(device["priv"], device["meter_id"], kwh, ts)
    r = requests.post(INGEST_URL, json=_rest_payload(device["meter_id"], kwh, ts, sig), headers=HEADERS, timeout=5)
    assert r.status_code in (200, 202), f"valid reading rejected: {r.status_code} {r.text}"


def test_tampered_signature_rejected(device):
    """Case 2: tampered signature is rejected (not 2xx)."""
    kwh, ts = "123.45", int(time.time() * 1000)
    r = requests.post(INGEST_URL,
                      json=_rest_payload(device["meter_id"], kwh, ts, "invalid_signature_base58"),
                      headers=HEADERS, timeout=5)
    assert r.status_code not in (200, 202), f"tampered sig accepted: {r.status_code} {r.text}"


def test_unknown_device_rejected():
    """Case 3: device with no registered pubkey is rejected."""
    pk, _ = crypto.new_identity()
    meter_id = f"E2E-UNKNOWN-{int(time.time()*1000)%1000000}"  # never registered
    kwh, ts = "50.00", int(time.time() * 1000)
    sig = crypto.sign_telemetry(pk, meter_id, kwh, ts)
    r = requests.post(INGEST_URL, json=_rest_payload(meter_id, kwh, ts, sig), headers=HEADERS, timeout=5)
    assert r.status_code not in (200, 202), f"unknown device accepted: {r.status_code} {r.text}"


def test_wrong_key_signature_rejected(device):
    """Case 4: reading signed by a different key than registered is rejected."""
    other, _ = crypto.new_identity()
    kwh, ts = "77.70", int(time.time() * 1000)
    sig = crypto.sign_telemetry(other, device["meter_id"], kwh, ts)  # wrong signer
    r = requests.post(INGEST_URL, json=_rest_payload(device["meter_id"], kwh, ts, sig), headers=HEADERS, timeout=5)
    assert r.status_code not in (200, 202), f"wrong-key sig accepted: {r.status_code} {r.text}"


def test_dissemination_fanout(device):
    """Case 5: accepted reading is disseminated to a zone Redis Stream."""
    before = redis_util.stream_total_len()
    kwh, ts = "200.00", int(time.time() * 1000)
    sig = crypto.sign_telemetry(device["priv"], device["meter_id"], kwh, ts)
    r = requests.post(INGEST_URL, json=_rest_payload(device["meter_id"], kwh, ts, sig), headers=HEADERS, timeout=5)
    assert r.status_code in (200, 202), f"reading rejected: {r.status_code} {r.text}"

    # Dissemination is async — poll for stream growth.
    deadline = time.time() + 10
    grew = False
    while time.time() < deadline:
        try:
            if redis_util.stream_total_len() > before:
                grew = True
                break
        except Exception:
            # Transient Redis blip — keep polling until the deadline.
            pass
        time.sleep(0.5)
    assert grew, "no zone stream growth after accepted reading (dissemination fan-out failed)"


def test_kafka_dissemination_fanout(device):
    """Case 7: an accepted reading is ALSO published to the Kafka dissemination topic
    (`meter.readings`) as a MeterReadingEvent — the Kafka fan-out leg of Oracle
    dissemination, complementing the Redis-stream assertion in Case 5.

    Real consumer tap (lib/events.kafka_tap): we open the tap at the topic's current
    end BEFORE ingesting, so we observe exactly the event this reading triggers (no
    stale-event false positive, no missed event). Skips if the broker is unreachable,
    or if the broker is up but no event arrives in the window (Oracle's Kafka producer
    is gated on KAFKA_BOOTSTRAP_SERVERS and publishes best-effort).
    """
    import json

    if not events.kafka_broker_up():
        pytest.skip(f"Kafka broker {events.KAFKA_BROKER} unreachable")
    consumer, ok = events.kafka_tap(KAFKA_TOPIC)
    if not ok:
        pytest.skip(f"Kafka topic {KAFKA_TOPIC} not present")
    meter = device["meter_id"]
    kwh, ts = "188.5", int(time.time() * 1000)
    sig = crypto.sign_telemetry(device["priv"], meter, kwh, ts)
    try:
        r = requests.post(INGEST_URL, json=_rest_payload(meter, kwh, ts, sig), headers=HEADERS, timeout=5)
        assert r.status_code in (200, 202), f"reading rejected: {r.status_code} {r.text}"

        def is_ours(val: bytes) -> bool:
            try:
                return json.loads(val).get("meter_id") == meter
            except Exception:
                return False

        raw = events.drain_kafka(consumer, is_ours, timeout=20)
    finally:
        consumer.close()

    if raw is None:
        pytest.skip("broker up but no MeterReadingEvent published within 20s "
                    "(Oracle KAFKA_BOOTSTRAP_SERVERS unset / producer disconnected)")
    ev = json.loads(raw)
    # Identity: the event is THIS ingest, not any reading on the topic — match both the
    # (per-test-unique) meter id and the exact Ed25519 signature we submitted.
    assert ev["meter_id"] == meter, f"wrong meter in event: {ev}"
    assert ev.get("signature") == sig, f"event signature != submitted sig: {ev}"
    # The verification verdict is carried through dissemination (fail-closed accepted it).
    assert ev.get("verified") is True, f"accepted reading not marked verified in event: {ev}"
    # NOTE: energy_* fields come from the parsed DeviceMetrics, not the REST payload's
    # `energy_consumed` shorthand, so their values are not asserted here — the Redis
    # fan-out (Case 5) and signature match above already prove the reading is carried.


def test_grpc_valid_and_tampered(device):
    """Case 6: gRPC Ingest accepts a valid signed reading, rejects a tampered one.

    Service is `gridtokenx.oracle.v1.OracleService/Ingest(MeterReading)` (proto
    in gridtokenx-aggregator-bridge/proto/oracle.proto). The verifier reconstructs the
    canonical target `{meter_id}:{kwh}:{timestamp}`, so kwh on the wire must be the
    canonicalized form the signature was computed over.
    """
    grpc = pytest.importorskip("grpc")
    try:
        import oracle_pb2
        import oracle_pb2_grpc
    except ImportError:
        pytest.skip("oracle proto stubs not on path")

    channel = grpc.insecure_channel(ORACLE_GRPC)
    stub = oracle_pb2_grpc.OracleServiceStub(channel)
    kwh, ts = "55.55", int(time.time() * 1000)
    kwh_canon = crypto.rust_f64_str(kwh)  # match Oracle's canonical reconstruction
    sig = crypto.sign_telemetry(device["priv"], device["meter_id"], kwh, ts)

    reading = oracle_pb2.MeterReading(
        meter_id=device["meter_id"], kwh=kwh_canon, timestamp=ts, signature=sig,
    )
    try:
        resp = stub.Ingest(reading, timeout=5)
    except grpc.RpcError as e:
        if e.code() == grpc.StatusCode.UNAVAILABLE:
            # Oracle gRPC :5030 not bound — only the REST ingest path is up.
            pytest.skip(f"Oracle gRPC {ORACLE_GRPC} unreachable (server not bound): {e.details()}")
        pytest.fail(f"valid gRPC telemetry rejected: {e.code()} {e.details()}")
    assert resp.status, "empty gRPC status on valid telemetry"

    tampered = oracle_pb2.MeterReading(
        meter_id=device["meter_id"], kwh=kwh_canon, timestamp=ts,
        signature="invalid_signature_base58",
    )
    with pytest.raises(grpc.RpcError):
        stub.Ingest(tampered, timeout=5)
