"""GridTokenX E2E — secure DLMS gRPC ingest for the settlement suites.

The 30_settlement tests were written against plaintext REST ingest (:4030
/v1/private-network/ingest). A hardened stack runs that gateway in mTLS +
secure-DLMS mode (plaintext REST → 426), so those tests skip. The working path on
both dev and secure stacks is `OracleService/BulkRawIngest` over an insecure gRPC
channel with an AES-256-GCM v4 frame (mirrors 20_oracle/test_dlms_secure_frame.py).

This centralises that path so each settlement test swaps its REST `_ingest`/`_payload`
for `new_meter` + `ingest` here.

Frame/window gotchas baked in:
  - LDN (the meter id IN the frame) is 8 bytes — `new_meter` keeps ids ≤8 chars so
    the id the bridge decodes matches the registered serial.
  - GCM nonce = manuf++ts_sec++ver, so two frames for the SAME meter+key MUST use
    distinct ts_sec or the nonce repeats. Callers vary ts_sec per reading.
  - the bridge derives the billing window from the frame ts (floor to 15 min), so
    pass ts_sec to place a reading in a chosen (closed) window.

gRPC host port is 50051 on the compose stack (env.sh / conftest default).
"""
import os
import time

import crypto
import dlms_frame
import redis_util

ORACLE_GRPC = os.getenv("AGGREGATOR_BRIDGE_GRPC", "localhost:50051")

# Serials of every meter created this session (via new_meter or track()).
# The 30_settlement suite-end fixture re-purges these: the bridge settles
# bins from memory, so a mint-outbox entry can appear AFTER a test's own
# cleanup() ran — per-test purge alone races the settlement sweep.
_created_serials = []


def track(serial: str) -> str:
    """Register a test meter serial for suite-end residue purging."""
    _created_serials.append(serial)
    return serial


def created_serials():
    return list(_created_serials)


def _grpc():
    import grpc  # imported lazily so a missing grpc skips at the test, not import time
    return grpc


def grpc_up(timeout: float = 4.0) -> bool:
    try:
        g = _grpc()
        g.channel_ready_future(g.insecure_channel(ORACLE_GRPC)).result(timeout=timeout)
        return True
    except Exception:
        return False


def stub():
    import oracle_pb2_grpc
    return oracle_pb2_grpc.OracleServiceStub(_grpc().insecure_channel(ORACLE_GRPC))


def new_meter(prefix: str, owner_user: str, *, wallet=None, register_pubkey=True,
              register_enc=True):
    """Register a secure meter. `prefix` is squashed to keep the id ≤8 chars (LDN).
    Skip `register_pubkey` to model an unregistered device (sig verify fails)."""
    pk, pub_hex = crypto.new_identity()
    meter = track(f"{prefix[:1]}{int(time.time() * 1000) % 10_000_000}")  # ≤8 chars
    enc_key = bytes(range(32))
    # Deliberately NOT a valid Base58 pubkey (meter ids inject 'I'/'0'): a
    # valid-looking wallet would actually mint GRX to a garbage address on a
    # stack with a live validator. Unmintable + purged in cleanup() is the
    # correct combination — do not "fix" this to valid Base58.
    w = wallet if wallet is not None else f"Wa11et{meter}".ljust(43, "1")[:43]
    if register_pubkey:
        redis_util.register_device_key(meter, pub_hex)
    if register_enc:
        redis_util.register_enckey(meter, enc_key.hex())
    redis_util.register_meter(meter, owner_user, wallet=w)
    return {"meter": meter, "priv": pk, "pub_hex": pub_hex, "wallet": w, "enc_key": enc_key}


def frame_for(handle, *, generated, consumed, ts_sec):
    """Build + sign an encrypted v4 frame (export_wh=generated kWh, import_wh=consumed
    kWh, in Wh) at ts_sec. Returns (frame, sig)."""
    tlv = dlms_frame.build_tlv(import_wh=int(consumed * 1000), export_wh=int(generated * 1000))
    frame = dlms_frame.frame_from_tlv(handle["meter"], tlv, handle["enc_key"], ts_sec=ts_sec)
    return frame, crypto.sign_raw(handle["priv"], frame)


def ingest(stub_, handle, *, generated, consumed, ts_sec, assert_ok=True):
    """Push one encrypted reading via BulkRawIngest. Returns the gRPC response."""
    import oracle_pb2
    frame, sig = frame_for(handle, generated=generated, consumed=consumed, ts_sec=ts_sec)
    req = oracle_pb2.BulkRawRequest(payload=dlms_frame.bulk_payload([(frame, sig)]), meter_count=1)
    resp = stub_.BulkRawIngest(req, timeout=10)
    if assert_ok:
        assert resp.processed_count == 1, f"encrypted reading rejected: {resp}"
    return resp


def cleanup(*handles):
    for h in handles:
        redis_util.unregister_device(h["meter"])
        redis_util.unregister_enckey(h["meter"])
        # Also drop billing bins + pending/parked mints, or the fake wallet
        # leaves a poison outbox entry retried forever on shared stacks.
        redis_util.purge_settlement_residue(h["meter"])
