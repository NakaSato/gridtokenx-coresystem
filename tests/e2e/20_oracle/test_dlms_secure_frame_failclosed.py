"""Suite 20 — Encrypted DLMS fail-closed matrix (security invariants, LIVE).

Asserts the secure-v4 decrypt policy (`apply_dlms_key_policy` /
`decode_secure_frame`, grpc/service.rs) does NOT regress against a running bridge:
a frame that cannot be securely decoded is SKIPPED, never silently decoded as
plaintext or counted as processed.

Several cases depend on how the bridge was launched. Rather than guess, the runner
DECLARES the bridge mode via env so tests skip LOUD (never skip-as-pass) when the
live bridge isn't in the required mode:

    E2E_BRIDGE_ENV          = dev | production      (mirror ENVIRONMENT)
    E2E_BRIDGE_ALLOW_PLAINTEXT = 0 | 1              (mirror ALLOW_PLAINTEXT_DLMS)

Drive the full matrix by running this file three times, once per bridge launch:
  1. dev, plaintext off  (default)      -> wrong-key + no-enckey-no-gate
  2. ENVIRONMENT=production              -> prod missing/wrong enckey
  3. ALLOW_PLAINTEXT_DLMS=true (dev)     -> plaintext-gate accept

Run: cd tests/e2e && python -m pytest 20_oracle/test_dlms_secure_frame_failclosed.py -v
"""
import os
import time

import pytest

import crypto
import dlms_frame
import redis_util

ORACLE_GRPC = os.getenv("AGGREGATOR_BRIDGE_GRPC", "localhost:5030")
BRIDGE_ENV = os.getenv("E2E_BRIDGE_ENV", "dev")
BRIDGE_ALLOW_PLAINTEXT = os.getenv("E2E_BRIDGE_ALLOW_PLAINTEXT", "0") == "1"
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

prod_only = pytest.mark.skipif(
    BRIDGE_ENV != "production",
    reason="needs a bridge launched with ENVIRONMENT=production (set E2E_BRIDGE_ENV=production)",
)
plaintext_gate_only = pytest.mark.skipif(
    not BRIDGE_ALLOW_PLAINTEXT,
    reason="needs a bridge launched with ALLOW_PLAINTEXT_DLMS=true (set E2E_BRIDGE_ALLOW_PLAINTEXT=1)",
)
no_plaintext_gate_only = pytest.mark.skipif(
    BRIDGE_ALLOW_PLAINTEXT,
    reason="needs a bridge WITHOUT ALLOW_PLAINTEXT_DLMS (set E2E_BRIDGE_ALLOW_PLAINTEXT=0)",
)


def _stub():
    return oracle_pb2_grpc.OracleServiceStub(grpc.insecure_channel(ORACLE_GRPC))


def _meter_id() -> str:
    return f"F{int(time.time() * 1000) % 1_000_000}"


def _send(entries):
    payload = dlms_frame.bulk_payload(entries)
    req = oracle_pb2.BulkRawRequest(payload=payload, meter_count=len(entries))
    try:
        return _stub().BulkRawIngest(req, timeout=5)
    except grpc.RpcError as e:
        if e.code() == grpc.StatusCode.UNAVAILABLE:
            pytest.skip(f"Bridge gRPC {ORACLE_GRPC} unreachable: {e.details()}")
        raise


def _register(meter_id, pub_hex, enckey_hex=None):
    redis_util.register_device_key(meter_id, pub_hex)
    redis_util.register_meter(meter_id, USER_ID)
    if enckey_hex is not None:
        redis_util.register_enckey(meter_id, enckey_hex)


def _cleanup(meter_id):
    redis_util.unregister_device(meter_id)
    redis_util.unregister_enckey(meter_id)


def test_wrong_enckey_skipped():
    """enckey present but WRONG: AES-GCM auth fails -> frame skipped, never plaintext.
    Holds in any mode (a bad key can't decrypt) — the core decrypt-fail invariant."""
    pk, pub = crypto.new_identity()
    meter_id = _meter_id()
    _register(meter_id, pub, enckey_hex=("aa" * 32))  # registered key...
    try:
        # ...but the frame is encrypted with a DIFFERENT key -> GCM tag mismatch.
        frame = dlms_frame.build_v4_frame(meter_id, enc_key=bytes([0xBB] * 32), import_wh=4242)
        sig = crypto.sign_raw(pk, frame)
        resp = _send([(frame, sig)])
        assert resp.processed_count == 0, (
            f"wrong-key frame was processed — decrypt-fail bypassed the gate: {resp}"
        )
    finally:
        _cleanup(meter_id)


def test_decrypt_fail_does_not_bypass_signature():
    """A frame with a VALID signature but an undecryptable body is still dropped:
    the decrypt gate runs independent of (and does not fall through) the sig gate."""
    pk, pub = crypto.new_identity()
    meter_id = _meter_id()
    _register(meter_id, pub, enckey_hex=("cc" * 32))
    try:
        frame = dlms_frame.build_v4_frame(meter_id, enc_key=bytes([0xDD] * 32), import_wh=1)
        sig = crypto.sign_raw(pk, frame)  # genuinely valid over the frame bytes
        resp = _send([(frame, sig)])
        assert resp.processed_count == 0, f"valid-sig but undecryptable frame ingested: {resp}"
    finally:
        _cleanup(meter_id)


@no_plaintext_gate_only
def test_no_enckey_no_gate_skipped():
    """No enckey + ALLOW_PLAINTEXT_DLMS off: a plaintext frame is skipped (dev default)."""
    pk, pub = crypto.new_identity()
    meter_id = _meter_id()
    _register(meter_id, pub, enckey_hex=None)  # no enckey
    try:
        frame = dlms_frame.build_v4_frame(meter_id, enc_key=None, import_wh=3131)  # plaintext
        sig = crypto.sign_raw(pk, frame)
        resp = _send([(frame, sig)])
        assert resp.processed_count == 0, f"unkeyed plaintext frame ingested without gate: {resp}"
    finally:
        _cleanup(meter_id)


@prod_only
def test_production_missing_enckey_skipped():
    """ENVIRONMENT=production + missing enckey + valid sig: frame SKIPPED, never
    decoded as plaintext. The headline fail-closed invariant."""
    pk, pub = crypto.new_identity()
    meter_id = _meter_id()
    _register(meter_id, pub, enckey_hex=None)
    try:
        frame = dlms_frame.build_v4_frame(meter_id, enc_key=None, import_wh=5050)  # plaintext body
        sig = crypto.sign_raw(pk, frame)
        resp = _send([(frame, sig)])
        assert resp.processed_count == 0, (
            f"production frame with no enckey was decoded — plaintext leak: {resp}"
        )
    finally:
        _cleanup(meter_id)


@prod_only
def test_production_wrong_enckey_skipped():
    """ENVIRONMENT=production + wrong enckey: GCM auth fails -> skipped (0)."""
    pk, pub = crypto.new_identity()
    meter_id = _meter_id()
    _register(meter_id, pub, enckey_hex=("ee" * 32))
    try:
        frame = dlms_frame.build_v4_frame(meter_id, enc_key=bytes([0xFF] * 32), import_wh=6060)
        sig = crypto.sign_raw(pk, frame)
        resp = _send([(frame, sig)])
        assert resp.processed_count == 0, f"production wrong-key frame ingested: {resp}"
    finally:
        _cleanup(meter_id)


@plaintext_gate_only
def test_plaintext_gate_accepts_unkeyed_frame():
    """ALLOW_PLAINTEXT_DLMS=true (dev) + no enckey: a plaintext frame is parsed and
    accepted. Confirms the dev escape hatch works — and, paired with the prod test
    above, that it is gated, not the default."""
    pk, pub = crypto.new_identity()
    meter_id = _meter_id()
    _register(meter_id, pub, enckey_hex=None)
    try:
        frame = dlms_frame.build_v4_frame(meter_id, enc_key=None, import_wh=7070)  # plaintext
        sig = crypto.sign_raw(pk, frame)
        resp = _send([(frame, sig)])
        assert resp.processed_count == 1, (
            f"plaintext frame not accepted under ALLOW_PLAINTEXT_DLMS=true: {resp}"
        )
    finally:
        _cleanup(meter_id)
