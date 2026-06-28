"""Suite 95 — InfluxDB fire-and-forget degrade (chaos).

The Aggregator Bridge writes realtime history to its OWN dedicated InfluxDB
(`gridtokenx-aggregator-influxdb`), but the documented invariant is that this write
NEVER blocks the operational path: `InfluxWriter::record` `try_send`s onto a bounded
channel and returns immediately; a background batcher flushes, and write failures are
logged + dropped (`aggregator-persistence/.../influxdb.rs:127-192`,
`router.rs:186` "fire-and-forget — a slow/down InfluxDB never blocks dissemination").

This proves it END TO END by breaking InfluxDB mid-run: with the container STOPPED, a
reading must still be accepted AND still fan out to the zone Redis stream. Because
InfluxDB is dedicated to the aggregator (not shared infra), stopping it has a single-
service blast radius — safe here. The container is always restarted in teardown.

Ingest goes over the **encrypted DLMS gRPC path** (`OracleService/BulkRawIngest`), not
plaintext REST: a hardened stack runs the IoT REST gateway in mTLS + secure-DLMS mode
(plaintext REST → 426), whereas BulkRawIngest over an insecure gRPC channel + an
AES-256-GCM v4 frame is accepted on both dev and secure stacks (mirrors
20_oracle/test_dlms_secure_frame.py). The aggregator gRPC host port is 50051 on the
compose stack (GRPC_PORT pinned to 50051, docker-compose.yml:660) — override
AGGREGATOR_BRIDGE_GRPC if your stack differs.

Run: E2E_RUN_CHAOS=1 cd tests/e2e && \
     AGGREGATOR_BRIDGE_GRPC=localhost:50051 python -m pytest 95_chaos/test_influx_fire_and_forget.py -v
"""
import os
import subprocess
import time

import pytest

import crypto
import dlms_frame
import redis_util

ORACLE_GRPC = os.getenv("AGGREGATOR_BRIDGE_GRPC", "localhost:5030")
USER_ID = "00000000-0000-0000-0000-000000000001"
INFLUX_CONTAINER = os.getenv("AGGREGATOR_INFLUX_CONTAINER", "gridtokenx-aggregator-influxdb")

grpc = pytest.importorskip("grpc")
try:
    import oracle_pb2
    import oracle_pb2_grpc
except ImportError:
    pytest.skip("oracle proto stubs not on path", allow_module_level=True)


def _redis_up() -> bool:
    try:
        redis_util.client().ping()
        return True
    except Exception:
        return False


def _grpc_up() -> bool:
    try:
        grpc.channel_ready_future(grpc.insecure_channel(ORACLE_GRPC)).result(timeout=4)
        return True
    except Exception:
        return False


def _container_exists(name: str) -> bool:
    r = subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}"],
                       capture_output=True, text=True)
    return name in r.stdout.split()


def _container_running(name: str) -> bool:
    r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                       capture_output=True, text=True)
    return name in r.stdout.split()


pytestmark = pytest.mark.skipif(
    not (_redis_up() and _grpc_up() and _container_exists(INFLUX_CONTAINER)),
    reason="aggregator gRPC/redis down or dedicated influx container absent",
)


def _stub():
    return oracle_pb2_grpc.OracleServiceStub(grpc.insecure_channel(ORACLE_GRPC))


def _ingest_encrypted(stub, meter_id, priv, enc_key, *, import_wh=5000, export_wh=1200):
    """Build + sign an encrypted v4 frame and push it via BulkRawIngest. Returns the
    gRPC response (processed_count / status)."""
    frame = dlms_frame.build_v4_frame(meter_id, enc_key=enc_key,
                                      import_wh=import_wh, export_wh=export_wh)
    sig = crypto.sign_raw(priv, frame)
    payload = dlms_frame.bulk_payload([(frame, sig)])
    req = oracle_pb2.BulkRawRequest(payload=payload, meter_count=1)
    try:
        return stub.BulkRawIngest(req, timeout=8)
    except grpc.RpcError as e:
        if e.code() == grpc.StatusCode.UNAVAILABLE:
            pytest.skip(f"Bridge gRPC {ORACLE_GRPC} unreachable: {e.details()}")
        raise


def _register(prefix: str):
    """Register a fresh secure meter (pubkey + enckey + owner). ≤8 chars for the LDN."""
    pk, pub_hex = crypto.new_identity()
    meter = f"{prefix}{int(time.time() * 1000) % 1_000_000}"
    enc_key = bytes(range(32))
    redis_util.register_device_key(meter, pub_hex)
    redis_util.register_meter(meter, USER_ID)
    redis_util.register_enckey(meter, enc_key.hex())
    return meter, pk, enc_key


@pytest.fixture
def influx_restored():
    """Ensure the dedicated InfluxDB container is restarted after the test, whatever
    happens — chaos must not leave a dependency down for the next run."""
    yield
    if not _container_running(INFLUX_CONTAINER):
        subprocess.run(["docker", "start", INFLUX_CONTAINER], capture_output=True, text=True)
        time.sleep(2)  # let it come back healthy before the next suite


def test_ingest_survives_influxdb_down(influx_restored):
    meter, pk, enc_key = _register("C")
    stub = _stub()
    try:
        # 1. Baseline (InfluxDB UP): an encrypted reading is decrypted + disseminates
        #    (processed_count==1 proves the bridge handled THIS reading; the new
        #    zone-stream entry proves it fanned out).
        before = redis_util.max_zone_stream_id()
        r = _ingest_encrypted(stub, meter, pk, enc_key, import_wh=7000)
        assert r.processed_count == 1, f"baseline ingest failed: {r}"
        assert redis_util.wait_zone_stream_advanced(before), "baseline reading did not disseminate (precondition broken)"

        # 2. Break InfluxDB mid-run.
        stop = subprocess.run(["docker", "stop", INFLUX_CONTAINER], capture_output=True, text=True)
        assert stop.returncode == 0, f"could not stop {INFLUX_CONTAINER}: {stop.stderr}"
        assert not _container_running(INFLUX_CONTAINER), "influx container still running after stop"

        # 3. With InfluxDB DOWN: ingest must still be processed AND still disseminate.
        before2 = redis_util.max_zone_stream_id()
        r2 = _ingest_encrypted(stub, meter, pk, enc_key, import_wh=9000)
        assert r2.processed_count == 1, \
            f"ingest blocked/failed while InfluxDB down — NOT fire-and-forget: {r2}"
        assert redis_util.wait_zone_stream_advanced(before2), \
            "reading did not disseminate while InfluxDB down — write path coupled to InfluxDB"
    finally:
        redis_util.unregister_device(meter)
        redis_util.unregister_enckey(meter)
