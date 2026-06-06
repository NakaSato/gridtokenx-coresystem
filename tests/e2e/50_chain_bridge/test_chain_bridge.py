"""Suite 50 — Chain Bridge gRPC reads (ConnectRPC) + auth isolation.

Chain Bridge exposes ConnectRPC (gridtokenx.chain.v1.ChainBridgeService) — callable
over plain HTTP POST + JSON (Connect protocol), so no proto codegen needed here.

Reads require a ServiceRole. Dev server must run with CHAIN_BRIDGE_INSECURE=true
(grants Admin) or CHAIN_BRIDGE_ALLOW_HEADER_AUTH=1 (trusts x-gridtokenx-role header);
otherwise strict mTLS is required and these HTTP tests skip.

NATS write path (chain.tx.submit / simulate) is exercised indirectly via IAM onboard
(suite 10) and settlement (suite 30); RBAC policy is covered by the Rust invariants
test wrapped in run.sh. This suite focuses on read correctness + role enforcement.

Run: cd tests/e2e && python -m pytest 50_chain_bridge -v
"""
import os

import pytest
import requests

GRPC = os.getenv("CHAIN_BRIDGE_GRPC", "localhost:5040")
BASE = os.getenv("CHAIN_BRIDGE_HTTP", f"http://{GRPC}")
SVC = "gridtokenx.chain.v1.ChainBridgeService"
ADMIN_ROLE = {"x-gridtokenx-role": "admin"}

SYSTEM_PROGRAM = "11111111111111111111111111111111"  # exists on any cluster


def connect_call(method: str, body: dict, headers: dict = None, timeout: float = 8.0):
    """Connect unary call. Returns (status_code, json|text)."""
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    r = requests.post(f"{BASE}/{SVC}/{method}", json=body, headers=h, timeout=timeout)
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, r.text


def _reachable() -> bool:
    try:
        connect_call("GetSlot", {}, ADMIN_ROLE, timeout=4)
        return True
    except requests.RequestException:
        return False


pytestmark = pytest.mark.skipif(
    not _reachable(),
    reason="Chain Bridge unreachable over plain HTTP (mTLS-only or down). "
           "Start with CHAIN_BRIDGE_INSECURE=true for dev e2e.",
)


def _authorized() -> bool:
    """True if server accepts header/insecure auth (reads return 200)."""
    code, _ = connect_call("GetSlot", {}, ADMIN_ROLE)
    return code == 200


# --- Read correctness ----------------------------------------------------

def test_get_slot_liveness():
    """Case 1: GetSlot returns a slot — Chain Bridge -> validator link alive."""
    if not _authorized():
        pytest.skip("server in strict mTLS mode; cannot auth over plain HTTP")
    code, body = connect_call("GetSlot", {}, ADMIN_ROLE)
    assert code == 200, f"GetSlot failed: {code} {body}"
    assert "slot" in body and int(body["slot"]) > 0, f"invalid slot: {body}"


def test_get_latest_blockhash():
    """Case 2: GetLatestBlockhash returns a non-empty blockhash."""
    if not _authorized():
        pytest.skip("strict mTLS mode")
    code, body = connect_call("GetLatestBlockhash", {}, ADMIN_ROLE)
    assert code == 200, f"GetLatestBlockhash failed: {code} {body}"
    assert body.get("blockhash"), f"empty blockhash: {body}"


def test_get_balance_system_program():
    """Case 3: GetBalance returns lamports for an existing account."""
    if not _authorized():
        pytest.skip("strict mTLS mode")
    code, body = connect_call("GetBalance", {"pubkey": SYSTEM_PROGRAM}, ADMIN_ROLE)
    assert code == 200, f"GetBalance failed: {code} {body}"
    # Connect JSON maps uint64 -> string or number; accept both.
    assert "lamports" in body, f"no lamports in response: {body}"
    int(body["lamports"])  # parses


def test_get_balance_invalid_pubkey_structured_error():
    """Case 4: malformed pubkey yields a structured error, not a silent 200."""
    if not _authorized():
        pytest.skip("strict mTLS mode")
    code, body = connect_call("GetBalance", {"pubkey": "not-a-valid-pubkey"}, ADMIN_ROLE)
    assert code != 200, f"invalid pubkey accepted: {code} {body}"
    if isinstance(body, dict):
        assert body.get("code") or body.get("message"), f"unstructured error: {body}"


# --- Auth isolation ------------------------------------------------------

def test_no_role_rejected():
    """Case 5: read without any role is denied (unless server in insecure mode)."""
    # CHAIN_BRIDGE_INSECURE grants Admin to everyone -> isolation not testable here.
    if os.getenv("CHAIN_BRIDGE_INSECURE", "").lower() == "true":
        pytest.skip("CHAIN_BRIDGE_INSECURE=true: all callers are Admin")
    code, body = connect_call("GetSlot", {})  # no role header
    assert code in (401, 403), f"unauthenticated read not denied: {code} {body}"


def test_unknown_role_rejected():
    """Case 6: an unrecognized role string is denied."""
    if os.getenv("CHAIN_BRIDGE_INSECURE", "").lower() == "true":
        pytest.skip("CHAIN_BRIDGE_INSECURE=true: all callers are Admin")
    code, body = connect_call("GetSlot", {}, {"x-gridtokenx-role": "bogus-role"})
    assert code in (401, 403), f"bogus role not denied: {code} {body}"
