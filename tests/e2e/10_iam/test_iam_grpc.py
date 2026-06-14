"""Suite 10 (gRPC parity) — IAM IdentityService over ConnectRPC (:5010).

The bash `10_iam/run.sh` covers the REST surface; this adds the gRPC parity the
plan called for (Phase 1, previously REST-only). IAM's IdentityService is a
ConnectRPC service (HTTP/2 + JSON, same Connect protocol as Chain Bridge / Noti /
Trading), so we call it over plain HTTP POST+JSON at
  http://<host>:5010/identity.IdentityService/<Method>
with JSON bodies/responses in camelCase (Connect's default JSON casing).

AUTH: every IdentityService method gates on ServiceRole::from_headers + require_any
(identity_grpc.rs). The api-gateway role needs the shared gateway secret (same model
as Trading): role string in `x-gridtokenx-role`, secret in
`x-gridtokenx-gateway-secret` (dev default when CHAIN_BRIDGE_INSECURE=true). Without a
recognised role the call is PermissionDenied -> HTTP 403.

PARITY: the JWT is minted by IAM REST (conftest `new_user`); we assert the gRPC
VerifyToken / GetUserInfo decode it to the SAME identity (userId == REST `sub`,
username matches) — i.e. REST and gRPC share one JWT/identity view.

Run: cd tests/e2e && python -m pytest 10_iam/test_iam_grpc.py -v
"""
import os

import pytest
import requests

# IAM gRPC speaks Connect over HTTP — derive an http:// base from the host:port.
_grpc_hostport = os.getenv("IAM_GRPC", "localhost:5010")
IAM_GRPC_HTTP = os.getenv("IAM_GRPC_HTTP", "http://" + _grpc_hostport)
GATEWAY_SECRET = os.getenv("GATEWAY_SECRET", "gridtokenx-gateway-secret-2025")


def _svc_headers(role="api-gateway"):
    h = {"Content-Type": "application/json", "x-gridtokenx-role": role}
    if role == "api-gateway":
        # api-gateway degrades to Unknown (-> 403) unless the secret matches.
        h["x-gridtokenx-gateway-secret"] = GATEWAY_SECRET
    return h


def _call(method, body, headers=None):
    url = f"{IAM_GRPC_HTTP}/identity.IdentityService/{method}"
    return requests.post(url, json=body, headers=headers if headers is not None else _svc_headers(), timeout=8)


def _up():
    try:
        # A bad token still returns 200 (handler reports valid:false), so this only
        # probes transport/role wiring, not token validity.
        _call("VerifyToken", {"token": "probe.bad.token"})
        return True
    except requests.RequestException:
        return False


pytestmark = pytest.mark.skipif(not _up(), reason="IAM gRPC (:5010) unreachable")


def _field(j, *names):
    """First present key among names (handles camelCase/snake_case JSON casing)."""
    for n in names:
        if n in j:
            return j[n]
    return None


def test_grpc_verify_token_parity(new_user):
    """VerifyToken decodes the REST-issued JWT to the SAME identity (REST/gRPC parity)."""
    jwt = new_user["jwt"] or pytest.skip("no JWT from REST register/verify")
    sub = new_user["user_id"] or pytest.skip("no sub in JWT")
    r = _call("VerifyToken", {"token": jwt})
    assert r.status_code == 200, f"VerifyToken failed: {r.status_code} {r.text}"
    j = r.json()
    assert _field(j, "valid") is True, f"valid JWT not accepted by gRPC: {j}"
    assert _field(j, "userId", "user_id") == sub, \
        f"gRPC user id != REST sub (identity divergence): {j} vs {sub}"
    assert _field(j, "username") == new_user["username"], f"username mismatch: {j}"


def test_grpc_verify_token_rejects_garbage(new_user):
    """A malformed token decodes to valid:false (not a transport error).

    Connect JSON omits proto3 default-valued fields, so a rejected token comes back
    as just {"errorMessage": ...} with `valid` absent — absent == false."""
    r = _call("VerifyToken", {"token": "not.a.jwt"})
    assert r.status_code == 200, f"unexpected status: {r.status_code} {r.text}"
    j = r.json()
    assert _field(j, "valid") is not True, f"garbage token wrongly accepted: {r.text}"
    assert _field(j, "errorMessage", "error_message"), f"no error message for bad token: {r.text}"


def test_grpc_requires_service_role(new_user):
    """Without a recognised ServiceRole the call is PermissionDenied -> HTTP 403."""
    jwt = new_user["jwt"] or pytest.skip("no JWT")
    # No role header at all.
    r = _call("VerifyToken", {"token": jwt}, headers={"Content-Type": "application/json"})
    assert r.status_code == 403, f"missing-role gRPC call not denied: {r.status_code} {r.text}"
    assert "permission_denied" in r.text.lower() or "permission" in r.text.lower(), r.text


def test_grpc_get_user_info_parity(new_user):
    """GetUserInfo returns the same id as the JWT sub (parity with REST /me)."""
    jwt = new_user["jwt"] or pytest.skip("no JWT")
    sub = new_user["user_id"] or pytest.skip("no sub")
    r = _call("GetUserInfo", {"token": jwt})
    assert r.status_code == 200, f"GetUserInfo failed: {r.status_code} {r.text}"
    j = r.json()
    assert _field(j, "id") == sub, f"GetUserInfo id != JWT sub: {j} vs {sub}"
    assert _field(j, "username") == new_user["username"], f"username mismatch: {j}"
    assert _field(j, "role"), f"no role in GetUserInfo response: {j}"
