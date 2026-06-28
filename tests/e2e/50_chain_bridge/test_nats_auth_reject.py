"""Suite 50 — Chain Bridge NATS write-path AUTH REJECTION (negative gap).

`test_nats_tx.py` proves the happy path: a correctly-signed envelope signs + lands.
This file proves the *closed door* — the consumer's envelope-authentication gate
(`nats_consumer/auth.rs`, called at `consumer.rs:289` BEFORE RBAC / dedup / signing)
rejects every malformed credential when `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true`
(the dev compose default, docker-compose.yml:393). On rejection the bridge publishes
a `TxResultMessage{success:false, error:"envelope authentication failed: ..."}` to
the envelope's `reply_subject` and Term-acks the message (consumer.rs:296-308).

Three credential failures, each a distinct branch of the cert→CA→SAN→signature chain:

  - UNSIGNED          — no `auth` block at all → "unsigned envelope (signing required)"
  - TAMPERED SIGNATURE— valid cert, signature bytes corrupted → signature verify fails
  - SAN ↔ IDENTITY    — a valid cert whose SPIFFE SAN ≠ the envelope `service_identity`
                        → the cert↔identity binding the bridge enforces is broken

Why this needs NO validator: the auth gate runs and replies BEFORE the tx is ever
submitted, so the inert tx is built with a fixed all-zero blockhash and the validator
(and even the bridge's blockhash cache) is never consulted. Only NATS + the bridge's
NATS consumer must be up. If the consumer is down no reply arrives → we skip loudly
rather than hang or green-by-silence.

Run: cd tests/e2e && python -m pytest 50_chain_bridge/test_nats_auth_reject.py -v
"""
import asyncio
import time
import uuid

import pytest
from solders.hash import Hash
from solders.instruction import Instruction
from solders.message import Message
from solders.pubkey import Pubkey
from solders.transaction import Transaction

import envelope_auth
import nats_util

# Same dev fee-payer / ComputeBudget no-op tx shape as test_nats_tx.py — but the tx
# is never submitted (rejected at the auth gate), so a fixed zero blockhash is fine.
DEV_PAYER = Pubkey.from_string("EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ")
COMPUTE_BUDGET_PROGRAM = Pubkey.from_string("ComputeBudget111111111111111111111111111111")
KEY_ID = "platform_admin"

# A valid dev mTLS client identity + its matching cert (SAN == identity). Used as the
# correct pair for the unsigned/tampered cases, and as the MISMATCHED cert for the
# SAN case (signed with this cert but the envelope claims a different identity).
SERVICE_IDENTITY = "spiffe://gridtokenx.th/prod/settlement-service"
SERVICE_CERT = "settlement-service"
# A different, also-valid identity — used only as the claimed `service_identity` in the
# SAN-mismatch case so the bridge sees cert-SAN(settlement) != claimed(trading).
OTHER_IDENTITY = "spiffe://gridtokenx.th/prod/trading-service-matcher"


def _set_compute_unit_limit_ix(units: int = 200_000) -> Instruction:
    data = bytes([2]) + int(units).to_bytes(4, "little")
    return Instruction(COMPUTE_BUDGET_PROGRAM, data, [])


def _inert_tx() -> list:
    # Fixed all-zero blockhash: the tx is rejected at auth and never lands, so the
    # blockhash is irrelevant — keeping it constant makes the test validator-free.
    msg = Message.new_with_blockhash([_set_compute_unit_limit_ix()], DEV_PAYER, Hash.default())
    return list(bytes(Transaction.new_unsigned(msg)))


def _base_envelope(service_identity: str) -> dict:
    cid = str(uuid.uuid4())
    return {
        "correlation_id": cid,
        "idempotency_key": cid,
        "reply_subject": f"chain.tx.result.{cid}",
        "serialized_tx": _inert_tx(),
        "key_id": KEY_ID,
        "skip_preflight": False,
        "retry_count": 0,
        "service_identity": service_identity,
        "created_at_ms": int(time.time() * 1000),
    }


def _submit_expect_reply(envelope: dict) -> dict:
    """Publish to chain.tx.submit and await the reply. Skips (not fails) if no reply
    arrives — that means the bridge's NATS consumer is down, not that the gate broke."""
    try:
        return nats_util.request_reply_sync(
            "chain.tx.submit", envelope["reply_subject"], envelope, timeout=15.0
        )
    except (asyncio.TimeoutError, TimeoutError):
        pytest.skip("no reply on chain.tx.submit — bridge NATS consumer down")


pytestmark = pytest.mark.skipif(
    not nats_util.reachable(), reason="NATS bus unreachable"
)


def _assert_auth_rejected(result: dict):
    assert result.get("success") is False, f"expected auth rejection, got success: {result}"
    assert not result.get("signature"), f"rejected envelope must carry no signature: {result}"
    err = (result.get("error") or "").lower()
    assert "auth" in err or "sign" in err or "cert" in err, (
        f"rejection error should name the auth failure, got: {result!r}"
    )


def test_unsigned_envelope_rejected():
    """No `auth` block: with require_signed on, the bridge rejects as unsigned."""
    if not envelope_auth.material_available(SERVICE_CERT):
        pytest.skip(f"dev client cert '{SERVICE_CERT}' absent — run scripts/gen-certs.sh")
    envelope = _base_envelope(SERVICE_IDENTITY)
    # deliberately omit envelope["auth"]
    _assert_auth_rejected(_submit_expect_reply(envelope))


def test_tampered_signature_rejected():
    """Valid cert, corrupted signature bytes → signature verification fails."""
    if not envelope_auth.material_available(SERVICE_CERT):
        pytest.skip(f"dev client cert '{SERVICE_CERT}' absent — run scripts/gen-certs.sh")
    envelope = _base_envelope(SERVICE_IDENTITY)
    auth = envelope_auth.sign_for("submit", envelope, SERVICE_CERT)
    # Flip the trailing base64 char of the signature — same length, invalid bytes.
    sig = auth["signature"]
    auth["signature"] = sig[:-1] + ("A" if sig[-1] != "A" else "B")
    envelope["auth"] = auth
    _assert_auth_rejected(_submit_expect_reply(envelope))


def test_san_identity_mismatch_rejected():
    """Cert SAN != claimed service_identity → the cert↔identity binding is broken.

    The envelope is signed correctly (valid cert, valid signature over the canonical
    bytes that embed OTHER_IDENTITY) but the cert's SPIFFE SAN is settlement-service
    while the envelope claims the trading identity. The bridge requires SAN == claimed
    identity, so it rejects even though the signature itself verifies."""
    if not envelope_auth.material_available(SERVICE_CERT):
        pytest.skip(f"dev client cert '{SERVICE_CERT}' absent — run scripts/gen-certs.sh")
    envelope = _base_envelope(OTHER_IDENTITY)  # claim trading...
    envelope["auth"] = envelope_auth.sign_for("submit", envelope, SERVICE_CERT)  # ...sign w/ settlement cert
    _assert_auth_rejected(_submit_expect_reply(envelope))
