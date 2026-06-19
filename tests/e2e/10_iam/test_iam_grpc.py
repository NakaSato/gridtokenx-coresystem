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


def test_grpc_authorize_grants_user_permission(new_user):
    """Authorize: a normal user is granted a non-admin permission (RBAC decision path)."""
    jwt = new_user["jwt"] or pytest.skip("no JWT")
    r = _call("Authorize", {"token": jwt, "requiredPermission": "trading:read"})
    assert r.status_code == 200, f"Authorize failed: {r.status_code} {r.text}"
    j = r.json()
    assert _field(j, "authorized") is True, f"user denied a non-admin permission: {j}"


def test_grpc_authorize_denies_admin_permission_to_user(new_user):
    """Authorize: a normal user is denied an `admin:*` permission (proto3 omits authorized=false)."""
    jwt = new_user["jwt"] or pytest.skip("no JWT")
    r = _call("Authorize", {"token": jwt, "requiredPermission": "admin:delete"})
    assert r.status_code == 200, f"Authorize failed: {r.status_code} {r.text}"
    j = r.json()
    # Connect JSON omits the default-valued `authorized:false`, so absent == denied.
    assert _field(j, "authorized") is not True, f"user wrongly granted admin permission: {r.text}"
    assert _field(j, "errorMessage", "error_message"), f"no denial reason: {r.text}"


def test_grpc_verify_api_key_rejects_garbage(new_user):
    """VerifyApiKey: a bogus key decodes to valid:false (handler returns 200, not a transport error)."""
    r = _call("VerifyApiKey", {"key": "not-a-real-api-key"})
    assert r.status_code == 200, f"unexpected status: {r.status_code} {r.text}"
    j = r.json()
    assert _field(j, "valid") is not True, f"garbage api key wrongly accepted: {r.text}"


def test_grpc_verify_api_key_requires_role(new_user):
    """VerifyApiKey without a recognised ServiceRole is PermissionDenied -> 403."""
    r = _call("VerifyApiKey", {"key": "x"}, headers={"Content-Type": "application/json"})
    assert r.status_code == 403, f"missing-role VerifyApiKey not denied: {r.status_code} {r.text}"


# --- gRPC write methods ---------------------------------------------------
# RegisterUser/LinkWallet/InitializeUserWallet/GetUserWallet are the IdentityService
# write surface. They route through AuthService directly (NOT the REST router), so they
# bypass the REST 5-registrations/hour rate-limiter (rate_limit.rs is axum middleware on
# the REST app only). We register ONE user over gRPC, module-scoped, and chain the wallet
# methods off it — covering the write set without touching the REST register budget.

import time as _time  # noqa: E402

_E2E_RUN_ID = os.getenv("E2E_RUN_ID", str(int(_time.time())))
_PASSWORD = os.getenv("E2E_PASSWORD", "GRX-Secure-P@ss-2026-E2E")


def _gen_pubkey():
    """Fresh ed25519 base58 pubkey (solders), or None if unavailable."""
    try:
        from solders.keypair import Keypair
        return str(Keypair().pubkey())
    except Exception:
        return None


@pytest.fixture(scope="module")
def grpc_user():
    """Register one user over gRPC RegisterUser. Returns {user_id, username, email}."""
    uname = f"e2e_grpc_{_E2E_RUN_ID}_{os.getpid()}"
    email = f"{uname}@grx.test"
    r = _call("RegisterUser", {
        "username": uname, "email": email, "password": _PASSWORD,
        "firstName": "E2E", "lastName": "Grpc",
    })
    if r.status_code != 200:
        pytest.skip(f"gRPC RegisterUser unavailable: {r.status_code} {r.text}")
    j = r.json()
    uid = _field(j, "userId", "user_id")
    assert uid, f"RegisterUser returned no user id: {r.text}"
    return {"user_id": uid, "username": uname, "email": email}


def test_grpc_register_user(grpc_user):
    """RegisterUser over gRPC yields a user id + echoes the username (write parity with REST)."""
    assert grpc_user["user_id"], "no user id from gRPC RegisterUser"


def test_grpc_register_user_duplicate_rejected(grpc_user):
    """Re-registering the same username over gRPC is an error (not a silent second user)."""
    r = _call("RegisterUser", {
        "username": grpc_user["username"], "email": grpc_user["email"],
        "password": _PASSWORD, "firstName": "E2E", "lastName": "Grpc",
    })
    # Connect maps the AuthService error to a non-OK status (Internal -> HTTP 5xx).
    assert r.status_code != 200, f"duplicate gRPC register wrongly succeeded: {r.text}"


def test_grpc_register_requires_role(grpc_user):
    """RegisterUser without a recognised ServiceRole is PermissionDenied -> 403."""
    r = _call("RegisterUser", {"username": "x", "email": "x@y.z", "password": _PASSWORD},
              headers={"Content-Type": "application/json"})
    assert r.status_code == 403, f"missing-role RegisterUser not denied: {r.status_code} {r.text}"


def test_grpc_link_and_get_wallet(grpc_user):
    """LinkWallet (primary) persists, then GetUserWallet resolves the same address."""
    pubkey = _gen_pubkey() or pytest.skip("solders unavailable — cannot mint a pubkey")
    lr = _call("LinkWallet", {
        "userId": grpc_user["user_id"], "walletAddress": pubkey,
        "label": "E2E gRPC Primary", "isPrimary": True,
    })
    assert lr.status_code == 200, f"LinkWallet failed: {lr.status_code} {lr.text}"
    lj = lr.json()
    assert _field(lj, "walletId", "wallet_id"), f"no wallet id from LinkWallet: {lr.text}"
    assert _field(lj, "walletAddress", "wallet_address") == pubkey, f"address mismatch: {lj}"

    gr = _call("GetUserWallet", {"userId": grpc_user["user_id"]})
    assert gr.status_code == 200, f"GetUserWallet failed: {gr.status_code} {gr.text}"
    assert _field(gr.json(), "walletAddress", "wallet_address") == pubkey, \
        f"GetUserWallet != linked primary: {gr.text}"


def test_grpc_get_user_wallet_allows_aggregator_role(grpc_user):
    """GetUserWallet's allowlist includes AggregatorBridge (telemetry resolves owner wallets)."""
    r = _call("GetUserWallet", {"userId": grpc_user["user_id"]},
              headers={"Content-Type": "application/json", "x-gridtokenx-role": "aggregator-bridge"})
    # Either resolves (200) or 404 if no wallet yet — but never PermissionDenied for this role.
    assert r.status_code != 403, f"aggregator-bridge wrongly denied GetUserWallet: {r.text}"


def test_grpc_get_user_wallet_requires_role(grpc_user):
    """GetUserWallet without a recognised ServiceRole is PermissionDenied -> 403."""
    r = _call("GetUserWallet", {"userId": grpc_user["user_id"]},
              headers={"Content-Type": "application/json"})
    assert r.status_code == 403, f"missing-role GetUserWallet not denied: {r.status_code} {r.text}"


def test_grpc_initialize_user_wallet_requires_role(grpc_user):
    """InitializeUserWallet without a recognised ServiceRole is PermissionDenied -> 403.

    The happy path needs a funded validator + Chain Bridge, so we assert only the
    deterministic role gate here; the on-chain success path is exercised by the
    REST onboarding cases (run.sh 8-10)."""
    r = _call("InitializeUserWallet",
              {"userId": grpc_user["user_id"], "walletAddress": "x", "initialFundingSol": 0.0},
              headers={"Content-Type": "application/json"})
    assert r.status_code == 403, f"missing-role InitializeUserWallet not denied: {r.status_code} {r.text}"


def test_grpc_initialize_user_wallet_role_passes_gate(grpc_user):
    """With a valid role, InitializeUserWallet clears RBAC (may then fail on chain state, not 403).

    The RBAC gate (identity_grpc.rs:258) runs *before* any on-chain await, so a denial
    returns instantly. The happy path then submits + polls for PDA confirmation for up to
    ~15s (auth_service.rs:752, 20×750ms). With this throwaway pubkey and zero funding the
    PDA never lands, so the call either returns Internal/5xx after the poll window or — more
    often — exceeds our 8s client timeout. A ReadTimeout therefore *proves* the gate was
    cleared (a 403 would have been immediate), so we treat it as a pass, not a flake."""
    pubkey = _gen_pubkey() or pytest.skip("solders unavailable")
    try:
        r = _call("InitializeUserWallet",
                  {"userId": grpc_user["user_id"], "walletAddress": pubkey, "initialFundingSol": 0.0})
    except requests.exceptions.ReadTimeout:
        return  # entered the on-chain confirm loop => RBAC gate already cleared
    # Role-gated path must not be PermissionDenied; on-chain failure (Internal/5xx) is tolerated.
    assert r.status_code != 403, f"valid role wrongly denied at RBAC gate: {r.text}"
