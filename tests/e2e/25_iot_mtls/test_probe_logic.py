"""Suite 25 — unit tests for the skip predicate's decision logic.

These need no network and no stack, so they run on every `just e2e`. That is the
point: the transport cases in test_iot_mtls.py skip unless mTLS is enforced, and
a suite whose every case skips is indistinguishable from a suite that is broken.
These keep at least the load-bearing logic honest on a plain dev run.
"""
import requests

from mtls_probe import enforcement_verdict


def test_served_without_client_cert_means_not_enforced():
    """The conclusive negative: a cert-requiring server would not have served."""
    assert (
        enforcement_verdict(None, certs_present=True, port_open=True) is False
    )


def test_ssl_error_means_enforced():
    probe = requests.exceptions.SSLError("tlsv13 alert certificate required")
    assert enforcement_verdict(probe, certs_present=True, port_open=True) is True


def test_ssl_error_is_conclusive_without_consulting_the_port():
    """SSLError subclasses ConnectionError in requests.

    If the broader check came first it would swallow this case and defer to
    `port_open`, so a conclusive rejection would be misread whenever the port
    probe happened to fail.
    """
    probe = requests.exceptions.SSLError("tlsv13 alert certificate required")
    assert enforcement_verdict(probe, certs_present=True, port_open=False) is True


def test_dropped_connection_with_listener_means_enforced():
    """TLS 1.3 defers the server's alert past the client's handshake, so a
    refusal often surfaces as a dropped connection rather than an SSLError."""
    probe = requests.exceptions.ConnectionError("connection reset by peer")
    assert enforcement_verdict(probe, certs_present=True, port_open=True) is True


def test_dropped_connection_with_no_listener_means_stack_down():
    """The case that must NOT be mistaken for enforcement: nothing is running."""
    probe = requests.exceptions.ConnectionError("connection refused")
    assert enforcement_verdict(probe, certs_present=True, port_open=False) is False


def test_timeout_is_not_evidence_of_enforcement():
    probe = requests.exceptions.ReadTimeout("timed out")
    assert enforcement_verdict(probe, certs_present=True, port_open=True) is False


def test_missing_certs_short_circuits():
    """Without dev certs the suite cannot present one, so it cannot conclude
    anything about enforcement regardless of what the probe did."""
    probe = requests.exceptions.SSLError("tlsv13 alert certificate required")
    assert enforcement_verdict(probe, certs_present=False, port_open=True) is False
    assert enforcement_verdict(None, certs_present=False, port_open=True) is False
