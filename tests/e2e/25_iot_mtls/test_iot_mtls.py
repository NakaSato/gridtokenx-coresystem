"""Suite 25 — IoT gateway transport-level mTLS (Aggregator Bridge).

Asserts the three transport cases at the meter ingress, in the secure profile:

  1. plaintext HTTP to the TLS port  -> not served
  2. TLS with no client certificate  -> not served (rejected by the handshake)
  3. CA-signed client certificate    -> 200

Scope note — what this suite does NOT cover. The fourth half of "identity is
visible to the handler" is asserted in Rust, not here: no HTTP endpoint echoes
the SPIFFE identity back (adding one purely for a test would be an information
-disclosure surface), so that leg lives in
`gridtokenx-aggregator-bridge/crates/aggregator-api/src/middleware/mtls.rs`,
which drives a real handshake against a real handler and asserts the identity
arrives. This suite proves the transport boundary against the *deployed* stack;
that test proves the propagation. Neither subsumes the other.

mTLS is OFF by default (dev/e2e keep the plaintext conveniences), so every case
skips unless the bridge is actually enforcing client certs. Enable with:

    just gen-certs && just orb-up && just secure-up

**If you are running this to verify mTLS, set `IOT_MTLS_REQUIRED=1`.** Otherwise
a stack that silently stopped enforcing produces four skips and a green suite,
which reads the same as "nothing to test here". With the flag,
`test_enforcement_matches_expectation` turns that into a failure. The predicate
behind the skip is itself unit-tested in test_probe_logic.py, which needs no
stack and therefore runs on every `just e2e`.

Run: cd tests/e2e && python -m pytest 25_iot_mtls -v
"""
import os
import socket
import ssl
from pathlib import Path
from urllib.parse import urlparse

import pytest
import requests

from mtls_probe import enforcement_verdict

# The IoT gateway as the e2e harness addresses it (env.sh:15).
REST = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
_parsed = urlparse(REST)
HOST = _parsed.hostname or "localhost"
PORT = _parsed.port or 4030

# Dev mTLS material from `just gen-certs` (scripts/gen-certs.sh).
ROOT = Path(__file__).resolve().parents[3]
CERT_DIR = ROOT / "infra" / "certs"
CA = CERT_DIR / "ca.crt"
# The meter-side identity: spiffe://gridtokenx.th/prod/smartmeter-simulator
# (scripts/gen-certs.sh IDENTITIES). This is the cert a device presents.
CLIENT_CRT = CERT_DIR / "clients" / "smartmeter-simulator.crt"
CLIENT_KEY = CERT_DIR / "clients" / "smartmeter-simulator.key"

HTTPS = f"https://{HOST}:{PORT}"
TIMEOUT = float(os.getenv("IOT_MTLS_TIMEOUT", "8"))


def _certs_present() -> bool:
    return CA.is_file() and CLIENT_CRT.is_file() and CLIENT_KEY.is_file()


def _get(path: str, *, with_client_cert: bool):
    """GET over TLS, with or without presenting a client certificate."""
    kwargs = {"verify": str(CA), "timeout": TIMEOUT}
    if with_client_cert:
        kwargs["cert"] = (str(CLIENT_CRT), str(CLIENT_KEY))
    return requests.get(f"{HTTPS}{path}", **kwargs)


def _port_open() -> bool:
    try:
        with socket.create_connection((HOST, PORT), timeout=TIMEOUT):
            return True
    except OSError:
        return False


def _mtls_enforced() -> bool:
    """True when the bridge is up, speaking TLS, AND requiring a client cert.

    Probes rather than reading IOT_GATEWAY_TLS_CLIENT_CA: that var is set inside
    the container (secure.env), so the test shell cannot see it, and a stale
    export would misreport a stack that was never re-upped.

    The I/O lives here; the decision lives in `mtls_probe.enforcement_verdict`,
    which is unit-tested in test_probe_logic.py.
    """
    if not _certs_present():
        return False
    try:
        _get("/health", with_client_cert=False)
        probe = None  # served without a cert
    except requests.exceptions.RequestException as exc:
        probe = exc
    return enforcement_verdict(probe, certs_present=True, port_open=_port_open())


ENFORCED = _mtls_enforced()

# Opt-in tripwire. When set, this run is *expected* to be exercising mTLS, so a
# non-enforcing endpoint is a failure rather than a silent skip. Without it the
# suite can only skip, and a skip looks identical to "nothing to test here".
REQUIRED = os.getenv("IOT_MTLS_REQUIRED", "").lower() in ("1", "true", "yes")

mtls_only = pytest.mark.skipif(
    not ENFORCED,
    reason=(
        f"IoT gateway at {HTTPS} is not enforcing mTLS — run `just gen-certs && "
        f"just secure-up` (mTLS is off by default outside the secure profile). "
        f"Set IOT_MTLS_REQUIRED=1 to make this a failure instead."
    ),
)


def test_enforcement_matches_expectation():
    """Guards the skip itself: a run that asked for mTLS must not quietly skip.

    Always collected, never skipped when IOT_MTLS_REQUIRED is set — so a secure
    run cannot report green while every transport case below was skipped.
    """
    if not REQUIRED:
        pytest.skip("IOT_MTLS_REQUIRED not set — enforcement optional for this run")
    assert ENFORCED, (
        f"IOT_MTLS_REQUIRED is set but {HTTPS} is not enforcing client certs — "
        f"every transport case would have skipped and this suite would have "
        f"reported green without asserting anything"
    )


@mtls_only
def test_client_certificate_is_accepted():
    """Case 3: a CA-signed client cert completes the handshake and is served."""
    r = _get("/health", with_client_cert=True)
    assert r.status_code == 200, f"expected 200 with a valid client cert, got {r.status_code} {r.text}"


@mtls_only
def test_no_client_certificate_is_rejected():
    """Case 2: clientless TLS never gets a response.

    Asserted as "raises", not "returns 4xx", on purpose: the rejection happens
    in the TLS handshake, below HTTP, so there is no status code to inspect.
    Under TLS 1.3 the client's own handshake completes before the server's alert
    arrives, so this can surface as either an SSLError or a dropped connection —
    both mean the same thing and both are accepted here.
    """
    with pytest.raises((requests.exceptions.SSLError, requests.exceptions.ConnectionError)):
        r = _get("/health", with_client_cert=False)
        pytest.fail(f"clientless TLS was served: {r.status_code} {r.text!r}")


@mtls_only
def test_plaintext_http_is_rejected():
    """Case 1: plaintext to the TLS port is never served.

    Deliberately NOT asserted as a clean 4xx. The port is TLS-only, so a
    plaintext request is not a bad HTTP request — it is not HTTP at all. The
    server reads the request line as TLS record garbage and drops the
    connection, so the observable outcome is a transport error (or, at best, a
    non-HTTP garble), never a status code.
    """
    with pytest.raises(requests.exceptions.RequestException):
        r = requests.get(f"http://{HOST}:{PORT}/health", timeout=TIMEOUT)
        pytest.fail(f"plaintext HTTP was served on the TLS port: {r.status_code} {r.text!r}")


@mtls_only
def test_untrusted_client_certificate_is_rejected():
    """A self-signed cert from outside the dev CA must not be accepted.

    Guards the case the other three miss: that the server requires a cert but
    does not actually verify who signed it, which would make the whole boundary
    decorative.
    """
    import tempfile

    # Minimal self-signed leaf, generated on the fly so the suite carries no
    # committed key material.
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
    except ImportError:
        pytest.skip("cryptography not installed — cannot mint an untrusted cert")

    import datetime

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "impostor")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(hours=1))
        .sign(key, hashes.SHA256())
    )

    with tempfile.TemporaryDirectory() as d:
        crt_path = Path(d) / "impostor.crt"
        key_path = Path(d) / "impostor.key"
        crt_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        key_path.write_bytes(
            key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.TraditionalOpenSSL,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )

        with pytest.raises(
            (requests.exceptions.SSLError, requests.exceptions.ConnectionError, ssl.SSLError)
        ):
            r = requests.get(
                f"{HTTPS}/health",
                verify=str(CA),
                cert=(str(crt_path), str(key_path)),
                timeout=TIMEOUT,
            )
            pytest.fail(f"an untrusted client cert was served: {r.status_code} {r.text!r}")
