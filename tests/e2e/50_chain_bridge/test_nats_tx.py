"""Suite 50 — Chain Bridge NATS JetStream tx path (E2E_IMPL_PLAN lines 76/77/96).

The async write path: services don't call Solana directly — they bincode-serialize a
`solana_sdk::Transaction` and publish it as a JSON envelope to NATS. Chain Bridge's
JetStream pull consumer (`chain-bridge-worker` on stream `CHAIN_TX`, subjects
`chain.tx.*`) decodes it, signs the message with the platform key, submits to the
validator, and publishes a result back to the envelope's `reply_subject`
(`gridtokenx-chain-bridge/.../nats_consumer/consumer.rs`,
`gridtokenx-blockchain-core/.../rpc/nats_schema.rs`).

This proves that path end-to-end with a hand-built, inert-but-valid tx:

  - SUBMIT (`chain.tx.submit` → `chain.tx.result.{cid}`): the bridge signs + lands it;
    assert `success`, a non-empty base58 `signature`, and (test-only direct-RPC
    observation) that the signature is actually queryable on the validator — i.e. it
    LANDED, with a real slot. The bridge's own result `slot` is hardcoded 0
    (`service.rs:243`) so the landed-slot comes from the chain, not the envelope.
  - SIMULATE (`chain.tx.simulate` → `chain.tx.simulate.result.{cid}`): the bridge
    returns a simulation result and does NOT land — assert `success` and that the
    result carries no `signature` (simulate schema has compute_units/logs, no sig).

Tx construction (verified against `gridtokenx-chain-bridge/.../api/service.rs` +
`gridtokenx-blockchain-core/src/policy.rs`):
  - Dev stack runs `CHAIN_BRIDGE_INSECURE=true` → the bridge signs with the local dev
    keypair (`vault.rs` InsecureKeypairProvider, pubkey
    `EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ` = `SOLANA_PAYER_KEY`) and PolicyEngine
    is bypassed. The bridge attaches its signature at the fee-payer slot, so the tx's
    fee-payer MUST be that dev pubkey or the chain rejects the signature.
  - `key_id` MUST be `platform_admin` (the only authorised signing key; any other
    non-empty key_id is rejected, empty skips signing).
  - One ComputeBudget `SetComputeUnitLimit` instruction — a valid no-op tx (no funds
    move, always simulates/lands), and ComputeBudget is base-allowlisted by policy.
  - A real recent blockhash (read via Chain Bridge) so simulate doesn't fault on a
    zero blockhash (the bridge only auto-fills a zero blockhash on the SUBMIT path).
  - `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS` defaults true (docker-compose.yml:393), so the
    envelope MUST carry a valid `auth`: an ECDSA P-256/SHA-256 signature over the
    canonical bytes, made with the `settlement-service` dev mTLS client key (its SPIFFE
    SAN equals `service_identity`). Built via `lib/envelope_auth.py`, which mirrors
    `gridtokenx-blockchain-core/src/rpc/envelope_auth.rs`.

Run: cd tests/e2e && python -m pytest 50_chain_bridge/test_nats_tx.py -v
Skips gracefully if NATS / Chain Bridge / validator are unreachable.
"""
import os
import time
import uuid

import pytest
import requests
from solders.hash import Hash
from solders.instruction import Instruction
from solders.message import Message
from solders.pubkey import Pubkey
from solders.transaction import Transaction

import chain
import envelope_auth
import nats_util

# Dev signing key the insecure bridge uses; tx fee-payer must equal it (see header).
DEV_PAYER = Pubkey.from_string("EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ")
COMPUTE_BUDGET_PROGRAM = Pubkey.from_string("ComputeBudget111111111111111111111111111111")
# A known-mappable SPIFFE identity (settlement-service) → non-Unknown ServiceRole so
# the consumer's RBAC gate passes (blockchain-core/src/auth.rs).
SERVICE_IDENTITY = "spiffe://gridtokenx.th/prod/settlement-service"
# Dev mTLS client cert whose SPIFFE SAN == SERVICE_IDENTITY; signs the envelope auth.
SERVICE_CERT = "settlement-service"
KEY_ID = "platform_admin"

# Test-only DIRECT Solana RPC, used solely to CONFIRM a submitted signature landed
# (an observation a service would never make — services read via Chain Bridge). The
# host reaches the validator at localhost:8899 (compose: host.docker.internal:8899).
SOLANA_RPC = os.getenv("E2E_SOLANA_RPC", "http://localhost:8899")


def _set_compute_unit_limit_ix(units: int = 200_000) -> Instruction:
    # ComputeBudget SetComputeUnitLimit = tag byte 0x02 + u32 LE; no accounts.
    data = bytes([2]) + int(units).to_bytes(4, "little")
    return Instruction(COMPUTE_BUDGET_PROGRAM, data, [])


def _serialized_inert_tx(blockhash: str) -> list:
    """bincode bytes (as a JSON u8 array) of an unsigned inert tx the bridge will
    sign + land. solders' legacy `Transaction` wire form IS bincode, matching the
    bridge's `bincode::deserialize::<Transaction>`."""
    msg = Message.new_with_blockhash(
        [_set_compute_unit_limit_ix()], DEV_PAYER, Hash.from_string(blockhash)
    )
    tx = Transaction.new_unsigned(msg)
    return list(bytes(tx))


def _nats_up() -> bool:
    return nats_util.reachable()


def _chain_up() -> bool:
    return chain.reachable()


pytestmark = pytest.mark.skipif(
    not (_nats_up() and _chain_up()),
    reason="NATS bus or Chain Bridge unreachable",
)


def _signature_landed(sig: str, timeout: float = 20.0):
    """Poll the validator directly until `sig` has a confirmed status. Returns the
    status dict (with `slot`) or None. TEST-ONLY direct RPC — see module header."""
    deadline = time.time() + timeout
    body = {
        "jsonrpc": "2.0", "id": 1, "method": "getSignatureStatuses",
        "params": [[sig], {"searchTransactionHistory": True}],
    }
    while time.time() < deadline:
        try:
            r = requests.post(SOLANA_RPC, json=body, timeout=5)
            val = r.json().get("result", {}).get("value", [None])[0]
        except Exception:
            val = None
        if val is not None:
            return val
        time.sleep(1.0)
    return None


def test_nats_submit_signs_and_lands():
    blockhash = chain.get_latest_blockhash()
    cid = str(uuid.uuid4())
    reply = f"chain.tx.result.{cid}"
    envelope = {
        "correlation_id": cid,
        "idempotency_key": cid,  # stable per-op; unique run → no spurious dedup
        "reply_subject": reply,
        "serialized_tx": _serialized_inert_tx(blockhash),
        "key_id": KEY_ID,
        "skip_preflight": False,
        "retry_count": 0,
        "service_identity": SERVICE_IDENTITY,
        "created_at_ms": int(time.time() * 1000),
    }
    envelope["auth"] = envelope_auth.sign_for("submit", envelope, SERVICE_CERT)

    result = nats_util.request_reply_sync("chain.tx.submit", reply, envelope, timeout=30.0)

    assert result.get("success") is True, f"bridge rejected submit: {result}"
    sig = result.get("signature")
    assert sig, f"no signature in submit result: {result}"

    # The bridge returns a sig only after provider.send_transaction succeeded → it
    # was accepted by the validator. Confirm it actually landed (real slot), since
    # the bridge's own result.slot is hardcoded 0.
    status = _signature_landed(sig)
    assert status is not None, f"signature {sig} never landed on validator"
    assert status.get("slot", 0) > 0, f"landed but no slot: {status}"
    assert status.get("err") is None, f"tx landed with error: {status}"


def test_nats_simulate_returns_result_no_land():
    blockhash = chain.get_latest_blockhash()
    cid = str(uuid.uuid4())
    reply = f"chain.tx.simulate.result.{cid}"
    envelope = {
        "correlation_id": cid,
        "reply_subject": reply,
        "serialized_tx": _serialized_inert_tx(blockhash),
        "key_id": KEY_ID,
        "service_identity": SERVICE_IDENTITY,
        "created_at_ms": int(time.time() * 1000),
    }
    envelope["auth"] = envelope_auth.sign_for("simulate", envelope, SERVICE_CERT)

    result = nats_util.request_reply_sync("chain.tx.simulate", reply, envelope, timeout=30.0)

    assert result.get("success") is True, f"simulate failed: {result}"
    # Simulate must NOT land: its result schema carries compute_units/logs, never a
    # signature. Absence of a signature is the no-land assertion.
    assert "signature" not in result, f"simulate unexpectedly returned a signature: {result}"
    assert "logs" in result or "compute_units_consumed" in result, (
        f"simulate result missing expected fields: {result}"
    )
