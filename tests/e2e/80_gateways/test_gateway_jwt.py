"""Suite 80 — APISIX jwt-auth VALIDATION DEPTH (negative gap).

run.sh Case 10 proves a missing header and a garbage (unparseable) token both 401.
That only exercises "is a token present and shaped like a JWT". This file proves the
gateway actually *validates* a well-formed token — exp, HMAC signature, and consumer
key — by minting structurally valid HS256 tokens that each fail exactly one check:

  - VALID            — correct key + secret + future exp → NOT 401 (accepted by the
                       gateway; upstream may then 200/403, but the jwt-auth gate passed)
  - EXPIRED          — correct key + secret, exp in the past → 401
  - WRONG SIGNATURE  — correct key, signed with the wrong secret → 401
  - UNKNOWN CONSUMER — wrong `key` claim (no matching consumer) → 401

APISIX config: the shared jwt-auth plugin_config sets `key_claim_name: iss`
(apisix_conf/apisix.yaml:5), so a token is mapped to its consumer by the `iss` claim
(consumer key="gridtokenx-iam-service", HS256, dev secret — apisix.yaml:461-466);
then APISIX verifies the HMAC signature + exp.

Both a gateway-accepted token AND an upstream-rejected one can surface as HTTP 401, so
status alone is ambiguous. We distinguish by body: an APISIX jwt-auth rejection carries
`{"message":"failed to verify jwt"|"Invalid user key in JWT token"|...}`, whereas a
token that CLEARED the gateway is proxied to IAM and rejected there with a structured
upstream error (`{"error":{"code":"AUTH_1003",...}}`). So a valid token is proven by the
ABSENCE of a gateway-jwt-reject message, not by a 2xx.

Validation is network-independent (no rate-limit / ip-restriction involved), so this
runs against the dev stack as-is. Skips loudly if APISIX is unreachable.

Run: cd tests/e2e && python -m pytest 80_gateways/test_gateway_jwt.py -v
"""
import os

import pytest
import requests

import crypto

APISIX_URL = os.getenv("APISIX_URL", "http://localhost:4001")
# Consumer key carried in the `iss` claim (key_claim_name: iss). Must match
# apisix_conf/apisix.yaml:5 + :465-466 (dev tier). Overridable for CI.
JWT_ISS = os.getenv("APISIX_JWT_ISS", "gridtokenx-iam-service")
JWT_SECRET = os.getenv(
    "APISIX_JWT_SECRET",
    "dev-jwt-secret-key-minimum-32-characters-long-for-development-2025",
)
# A route under the jwt-auth plugin_config (apisix.yaml Case 10 uses /me, /orders).
AUTH_ROUTE = os.getenv("APISIX_AUTH_ROUTE", "/api/v1/me")

# Substrings that mark an APISIX jwt-auth (gateway-layer) rejection — as opposed to an
# upstream rejection of a token that already cleared the gateway.
_GATEWAY_JWT_REJECT = (
    "failed to verify jwt",
    "invalid user key in jwt token",
    "missing related consumer",
    "jwt token invalid",
    "missing user key in jwt token",
)


def _apisix_up() -> bool:
    try:
        requests.get(f"{APISIX_URL}/api/v1/public/grid-status", timeout=4)
        return True
    except requests.RequestException:
        return False


pytestmark = pytest.mark.skipif(not _apisix_up(), reason="APISIX gateway unreachable")


def _get(token: str):
    r = requests.get(f"{APISIX_URL}{AUTH_ROUTE}",
                     headers={"Authorization": f"Bearer {token}"}, timeout=8)
    return r.status_code, (r.text or "").lower()


def _gateway_rejected(text: str) -> bool:
    return any(m in text for m in _GATEWAY_JWT_REJECT)


def test_valid_token_clears_gateway():
    """Correct iss + secret + future exp → token CLEARS jwt-auth and reaches upstream.

    Proven by the absence of an APISIX jwt-auth rejection message (the upstream may
    still 401 our synthetic sub — that's fine; it means we got past the gate). If this
    were gateway-rejected, the negative cases below would prove nothing."""
    code, body = _get(crypto.mint_hs256_jwt(JWT_SECRET, sub="e2e-gw", ttl_secs=300, iss=JWT_ISS))
    if code in (0, 502, 503):
        pytest.skip(f"upstream for {AUTH_ROUTE} unavailable [{code}] — can't baseline")
    assert not _gateway_rejected(body), f"valid token wrongly rejected at gateway [{code}]: {body!r}"


def test_expired_token_rejected_at_gateway():
    """Correct iss + secret but exp in the past → APISIX 401 'failed to verify jwt'."""
    code, body = _get(crypto.mint_hs256_jwt(JWT_SECRET, sub="e2e-gw", ttl_secs=-300, iss=JWT_ISS))
    assert code == 401 and _gateway_rejected(body), f"expired JWT not gateway-rejected [{code}]: {body!r}"


def test_wrong_signature_rejected_at_gateway():
    """Correct iss but signed with the wrong secret → bad HMAC → APISIX 401."""
    code, body = _get(crypto.mint_hs256_jwt("not-the-real-secret-but-also-32-chars-long-xx",
                                            sub="e2e-gw", ttl_secs=300, iss=JWT_ISS))
    assert code == 401 and _gateway_rejected(body), f"wrong-sig JWT not gateway-rejected [{code}]: {body!r}"


def test_unknown_consumer_iss_rejected_at_gateway():
    """An `iss` claim with no matching consumer → APISIX 401 'Invalid user key'."""
    code, body = _get(crypto.mint_hs256_jwt(JWT_SECRET, sub="e2e-gw", ttl_secs=300,
                                            iss="no-such-consumer"))
    assert code == 401 and _gateway_rejected(body), f"unknown-iss JWT not gateway-rejected [{code}]: {body!r}"
