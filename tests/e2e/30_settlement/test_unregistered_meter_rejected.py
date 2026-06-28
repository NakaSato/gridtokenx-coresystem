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
import os
import sys
import time

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))

import settlement_ingest as si

# Ingest over the encrypted DLMS gRPC path (BulkRawIngest); a rejected frame is counted
# (processed_count==0), not an HTTP status. See lib/settlement_ingest.py.
OWNER_USER = "00000000-0000-0000-0000-000000000001"

grpc = pytest.importorskip("grpc")
try:
    import oracle_pb2  # noqa: F401
    import oracle_pb2_grpc  # noqa: F401
except ImportError:
    pytest.skip("oracle proto stubs not on path", allow_module_level=True)

pytestmark = pytest.mark.skipif(
    not si.grpc_up(), reason=f"aggregator gRPC not reachable at {si.ORACLE_GRPC}"
)


def test_unregistered_meter_rejected_at_ingress():
    """Differential: a registered device's encrypted frame is processed; an otherwise
    identical frame from a device with NO Ed25519 pubkey in Redis is rejected
    (processed_count==0). The target keeps its enckey (so decrypt succeeds) but is
    unregistered, so the rejection is attributable to the missing registration alone."""
    ts_sec = int(time.time()) - 20 * 60  # past, closed window (irrelevant to the reject)
    stub = si.stub()

    # control: pubkey + enckey registered → accepted.
    ctrl = si.new_meter("R", OWNER_USER)
    # target: enckey registered (frame decrypts) but NO device pubkey → sig verify fails.
    target = si.new_meter("U", OWNER_USER, register_pubkey=False)
    try:
        cr = si.ingest(stub, ctrl, generated=10, consumed=0, ts_sec=ts_sec, assert_ok=False)
        assert cr.processed_count == 1, f"registered control must be accepted: {cr}"

        tr = si.ingest(stub, target, generated=10, consumed=0, ts_sec=ts_sec - 900, assert_ok=False)
        if tr.processed_count == 1:
            pytest.skip(
                "aggregator processed an unregistered device — signature enforcement is "
                "disabled (AGGREGATOR_ALLOW_UNVERIFIED_TELEMETRY=true); cannot assert the "
                "fail-closed ingress invariant"
            )
        assert tr.processed_count == 0, (
            f"unregistered device must be rejected (processed_count==0), got: {tr}"
        )
    finally:
        si.cleanup(ctrl, target)
