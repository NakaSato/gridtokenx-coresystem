"""Pure decision logic for suite 25's skip predicate.

Split out from `test_iot_mtls.py` so the predicate that decides whether the
whole suite runs is itself testable without a network. That matters more than it
looks: if this logic wrongly says "not enforced", every transport case skips and
the suite reports green having asserted nothing — the same shape as the
no-entry-point bug called out in `tests/e2e/run.sh`, where a suite printed
PASSED while running nothing at all.
"""
import requests


def enforcement_verdict(probe, *, certs_present, port_open):
    """Does this probe outcome mean the endpoint is enforcing client certs?

    `probe` is the result of requesting /health *without* presenting a client
    certificate: `None` if the request was served, otherwise the exception it
    raised.

    - served            -> not enforced (a cert-requiring server would not serve)
    - SSLError          -> enforced (handshake refused)
    - ConnectionError   -> enforced only if something is actually listening;
                           under TLS 1.3 the server's rejection alert arrives
                           after the client's own handshake completes, so a
                           refusal reaches us as a dropped connection rather
                           than an SSLError. Distinguishing that from "the stack
                           is down" is what `port_open` is for.
    - anything else     -> not enforced (timeouts, DNS, bad URL: no evidence)

    Note SSLError must be checked before ConnectionError: in requests, SSLError
    is a *subclass* of ConnectionError, so the broader check would swallow it
    and make the verdict depend on `port_open` for a case that is already
    conclusive.
    """
    if not certs_present:
        return False
    if probe is None:
        return False
    if isinstance(probe, requests.exceptions.SSLError):
        return True
    if isinstance(probe, requests.exceptions.ConnectionError):
        return port_open
    return False
