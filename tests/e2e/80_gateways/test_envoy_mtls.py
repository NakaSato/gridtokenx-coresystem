"""Envoy edge mTLS enforcement — non-mTLS clients rejected at :4002.

Closes the E2E_IMPL_PLAN Phase 2 item "Envoy mTLS enforcement: non-mTLS client
at :4002 rejected" (was BLOCKED on the plaintext stub config — see TD-003). The
edge listener (`envoy_conf/envoy.yaml`) now sets `require_client_certificate:
true` against the dev CA, so:

  - plaintext HTTP                → connection fails (TLS required)
  - HTTPS with NO client cert     → TLS handshake fails (mutual auth)
  - HTTPS WITH a CA-signed client → proxied to the Aggregator IoT gateway

Dev mTLS material from `infra/certs/` (scripts/gen-certs.sh): `ca.crt` trust
root, a client cert/key under `clients/`. The edge server cert SAN is
`localhost`, so the request targets `https://localhost:4002`.

The edge now PROXIES authenticated requests to the Aggregator IoT gateway
(`aggregator-bridge:4010`), so the accepted-client case asserts the real
upstream `/health` response, not a stub. (Residual TD-003: the client SPIFFE
SAN is not yet mapped to a device/role at the edge.)
"""
import os

import pytest
import requests

CERTS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "infra", "certs"))
CA = os.path.join(CERTS, "ca.crt")
CLIENT_CRT = os.path.join(CERTS, "clients", "aggregator-bridge.crt")
CLIENT_KEY = os.path.join(CERTS, "clients", "aggregator-bridge.key")

HOST = os.getenv("ENVOY_EDGE_HOST", "localhost")
PORT = os.getenv("ENVOY_EDGE_PORT", "4002")
HTTPS = f"https://{HOST}:{PORT}/"
HTTP = f"http://{HOST}:{PORT}/"


def _edge_up() -> bool:
    # A clientless TLS attempt that *reaches* the listener fails the handshake
    # (SSLError); a dead port raises ConnectionError. Treat either connection
    # outcome as "reachable enough to test" only when certs exist.
    if not (os.path.exists(CA) and os.path.exists(CLIENT_CRT) and os.path.exists(CLIENT_KEY)):
        return False
    try:
        requests.get(HTTPS, cert=(CLIENT_CRT, CLIENT_KEY), verify=CA, timeout=4)
        return True
    except requests.exceptions.SSLError:
        # Handshake reached but failed (e.g. cert mismatch) — edge is up but
        # misconfigured; let the real assertions report it rather than skip.
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(
    not _edge_up(),
    reason="Envoy edge :4002 unreachable or dev certs (infra/certs/) missing",
)


def test_plaintext_http_rejected():
    # Plain HTTP bytes hitting a TLS listener → no HTTP response (reset / EOF).
    with pytest.raises(requests.exceptions.RequestException):
        requests.get(HTTP, timeout=5)


def test_https_without_client_cert_rejected():
    # Server requires a client certificate → mutual-TLS handshake fails.
    with pytest.raises(requests.exceptions.SSLError):
        requests.get(HTTPS, verify=CA, timeout=5)


def test_https_with_client_cert_proxied_to_aggregator():
    # A CA-signed client cert satisfies mTLS → the edge proxies to the Aggregator
    # IoT gateway. /health is unauthenticated upstream, so it round-trips 200 with
    # the gateway's identity — proving the edge routes to the real backend.
    r = requests.get(f"{HTTPS}health", cert=(CLIENT_CRT, CLIENT_KEY), verify=CA, timeout=5)
    assert r.status_code == 200, f"mTLS client should reach the upstream, got {r.status_code}"
    body = r.json()
    assert body.get("status") == "ok", f"unexpected upstream health: {body}"
    assert "iot-gateway" in body.get("service", ""), (
        f"expected the Aggregator IoT gateway upstream, got {body}"
    )
