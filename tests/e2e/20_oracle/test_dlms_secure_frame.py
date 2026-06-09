"""Suite 20 — Encrypted DLMS secure-v4 gRPC ingestion (the BulkRawIngest path).

Covers the AES-256-GCM secure-frame path the simulator does NOT drive: a client
builds a real encrypted v4 frame, seeds the per-device `enckey`, sends it over
gRPC `OracleService/BulkRawIngest`, and the bridge decrypts → ingests → fans out.

This is the live counterpart to the in-crate `apply_dlms_key_policy` unit tests:
here the bridge resolves the key from Redis and decrypts for real. Runs against a
DEV-mode bridge (ENVIRONMENT unset); the production fail-closed matrix lives in
test_dlms_secure_frame_failclosed.py.

Run: cd tests/e2e && python -m pytest 20_oracle/test_dlms_secure_frame.py -v
Skips gracefully if the bridge gRPC / Redis are unreachable or stubs are absent.
"""
import os
import time

import pytest

import crypto
import dlms_frame
import redis_util

ORACLE_GRPC = os.getenv("AGGREGATOR_BRIDGE_GRPC", "localhost:5030")
USER_ID = "00000000-0000-0000-0000-000000000001"


def _redis_up() -> bool:
    try:
        redis_util.client().ping()
        return True
    except Exception:
        return False


grpc = pytest.importorskip("grpc")
try:
    import oracle_pb2
    import oracle_pb2_grpc
except ImportError:
    pytest.skip("oracle proto stubs not on path", allow_module_level=True)

pytestmark = pytest.mark.skipif(not _redis_up(), reason="Redis unreachable")


def _stub():
    return oracle_pb2_grpc.OracleServiceStub(grpc.insecure_channel(ORACLE_GRPC))


def _meter_id() -> str:
    # LDN is a fixed 8-byte frame field — keep the id <= 8 chars so it round-trips.
    return f"M{int(time.time() * 1000) % 1_000_000}"


def _bulk_request(entries):
    payload = dlms_frame.bulk_payload(entries)
    return oracle_pb2.BulkRawRequest(payload=payload, meter_count=len(entries))


def _signed_frame(meter_id, key, enc_key, *, import_wh=5000, export_wh=1200, sign_key=None):
    """Build an encrypted v4 frame for `meter_id` and sign the frame bytes (raw 64B).

    `enc_key` encrypts the TLV block; `sign_key` (defaults to `key`) signs the frame.
    """
    frame = dlms_frame.build_v4_frame(
        meter_id, enc_key=enc_key, import_wh=import_wh, export_wh=export_wh
    )
    sig = crypto.sign_raw(sign_key or key, frame)
    return frame, sig


@pytest.fixture
def device():
    """Registered device with BOTH an Ed25519 pubkey and an AES-256 enckey."""
    pk, pub_hex = crypto.new_identity()
    enc_key = bytes(range(32))  # deterministic 32-byte AES-256 key
    meter_id = _meter_id()
    redis_util.register_device_key(meter_id, pub_hex)
    redis_util.register_meter(meter_id, USER_ID)
    redis_util.register_enckey(meter_id, enc_key.hex())
    yield {"meter_id": meter_id, "priv": pk, "pub_hex": pub_hex, "enc_key": enc_key}
    redis_util.unregister_device(meter_id)
    redis_util.unregister_enckey(meter_id)


def _grpc_or_skip(stub, req):
    try:
        return stub.BulkRawIngest(req, timeout=5)
    except grpc.RpcError as e:
        if e.code() == grpc.StatusCode.UNAVAILABLE:
            pytest.skip(f"Bridge gRPC {ORACLE_GRPC} unreachable: {e.details()}")
        raise


def test_encrypted_frame_decrypted_and_ingested(device):
    """Happy path: a correctly-keyed, correctly-signed encrypted frame is decrypted
    server-side and counted as processed. processed_count==1 is proof the bridge's
    AES-256-GCM decrypt of our Python-built frame succeeded — bytes match the codec."""
    frame, sig = _signed_frame(device["meter_id"], device["priv"], device["enc_key"])
    resp = _grpc_or_skip(_stub(), _bulk_request([(frame, sig)]))
    assert resp.processed_count == 1, f"encrypted frame not ingested: {resp}"
    assert resp.status == "success", f"unexpected status: {resp.status}"


def test_encrypted_frame_disseminated(device):
    """An ingested encrypted reading fans out to a zone Redis Stream (async)."""
    before = redis_util.stream_total_len()
    frame, sig = _signed_frame(device["meter_id"], device["priv"], device["enc_key"])
    resp = _grpc_or_skip(_stub(), _bulk_request([(frame, sig)]))
    assert resp.processed_count == 1, f"encrypted frame not ingested: {resp}"

    deadline = time.time() + 10
    while time.time() < deadline:
        if redis_util.stream_total_len() > before:
            return
        time.sleep(0.5)
    pytest.fail("no zone stream growth after ingested encrypted frame (fan-out failed)")


def test_mixed_bulk_batch_only_valid_counts(device):
    """A 3-frame batch — one good encrypted, one wrong-key (GCM fail), one bad-sig —
    processes ONLY the valid frame. Proves a decrypt/sig failure on a sibling frame
    does not bypass the gate or corrupt the batch."""
    good_frame, good_sig = _signed_frame(device["meter_id"], device["priv"], device["enc_key"])

    # Wrong-key device: enckey in Redis differs from the key used to encrypt -> GCM auth fails.
    wk_pk, wk_pub = crypto.new_identity()
    wk_id = _meter_id() + "B"
    redis_util.register_device_key(wk_id, wk_pub)
    redis_util.register_enckey(wk_id, ("11" * 32))  # not the key we encrypt with
    wrong_frame = dlms_frame.build_v4_frame(wk_id, enc_key=bytes([0x22] * 32), import_wh=9999)
    wrong_sig = crypto.sign_raw(wk_pk, wrong_frame)

    # Bad-sig device: correctly keyed/encrypted, but signed by the wrong key.
    bs_pk, bs_pub = crypto.new_identity()
    other_pk, _ = crypto.new_identity()
    bs_id = _meter_id() + "C"
    bs_enc = bytes([0x33] * 32)
    redis_util.register_device_key(bs_id, bs_pub)
    redis_util.register_enckey(bs_id, bs_enc.hex())
    bad_frame = dlms_frame.build_v4_frame(bs_id, enc_key=bs_enc, import_wh=7777)
    bad_sig = crypto.sign_raw(other_pk, bad_frame)  # wrong signer

    try:
        entries = [(good_frame, good_sig), (wrong_frame, wrong_sig), (bad_frame, bad_sig)]
        resp = _grpc_or_skip(_stub(), _bulk_request(entries))
        assert resp.processed_count == 1, (
            f"expected only the valid frame to process, got {resp.processed_count}"
        )
    finally:
        redis_util.unregister_device(wk_id)
        redis_util.unregister_enckey(wk_id)
        redis_util.unregister_device(bs_id)
        redis_util.unregister_enckey(bs_id)
