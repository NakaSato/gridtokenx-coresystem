"""Suite 60 — Noti Service (:5050). ConnectRPC noti.v1.NotificationService.

Noti is a synchronous gRPC dispatcher (SendNotification / GetNotificationStatus) — no
queue consumer; callers invoke it directly. ConnectRPC speaks Connect protocol, so we
call over plain HTTP POST + JSON (no proto codegen).

Run: cd tests/e2e && python -m pytest 60_noti -v
"""
import os
import time

import pytest
import requests

import crypto

GRPC = os.getenv("NOTI_GRPC", "localhost:5050")
BASE = os.getenv("NOTI_HTTP", f"http://{GRPC}")
SVC = "noti.v1.NotificationService"

# Noti's gRPC gate (crates/noti-api/src/grpc.rs) requires an HS256 bearer signed
# with the service JWT_SECRET. Mint one with the dev secret (override via env).
NOTI_JWT_SECRET = os.getenv(
    "NOTI_JWT_SECRET",
    "dev-jwt-secret-key-minimum-32-characters-long-for-development-2025",
)
_BEARER = crypto.mint_hs256_jwt(NOTI_JWT_SECRET)


def call(method, body, timeout=8):
    r = requests.post(f"{BASE}/{SVC}/{method}", json=body,
                      headers={"Content-Type": "application/json",
                               "Authorization": f"Bearer {_BEARER}"}, timeout=timeout)
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, r.text


def _up():
    try:
        call("SendNotification", {}, timeout=4)
        return True
    except requests.RequestException:
        return False


pytestmark = pytest.mark.skipif(not _up(), reason="Noti Service unreachable over HTTP")


def _send(idempotency_key=None, recipient="e2e@grx.test"):
    body = {
        "channel": "EMAIL",
        "recipient": recipient,
        "template_id": "welcome",
        "variables_json": "{\"name\":\"E2E\"}",
        "user_id": "00000000-0000-0000-0000-000000000001",
    }
    if idempotency_key:
        body["idempotency_key"] = idempotency_key
    return call("SendNotification", body)


def test_send_notification_accepted():
    """Case 1: SendNotification returns a notification id + status."""
    code, body = _send(idempotency_key=f"e2e-{int(time.time()*1000)}")
    assert code == 200, f"SendNotification failed: {code} {body}"
    assert isinstance(body, dict) and body.get("notificationId") or body.get("notification_id"), \
        f"no notification id: {body}"


def test_get_notification_status():
    """Case 2: status of a just-sent notification is queryable."""
    code, body = _send(idempotency_key=f"e2e-{int(time.time()*1000)}")
    if code != 200:
        pytest.skip(f"send failed: {code} {body}")
    nid = body.get("notificationId") or body.get("notification_id")
    # ConnectRPC JSON maps snake_case + camelCase to the same proto field and rejects
    # the duplicate ("duplicate field notificationId"). Send only the canonical camelCase.
    code2, body2 = call("GetNotificationStatus", {"notificationId": nid})
    assert code2 == 200, f"GetNotificationStatus failed: {code2} {body2}"
    assert (body2.get("status") or "").strip(), f"empty status: {body2}"


def test_idempotency_key_dedups():
    """Case 3: same idempotency_key returns the same notification (no duplicate)."""
    key = f"e2e-idem-{int(time.time()*1000)}"
    c1, b1 = _send(idempotency_key=key)
    c2, b2 = _send(idempotency_key=key)
    if c1 != 200 or c2 != 200:
        pytest.skip("send not accepted; cannot assert idempotency")
    id1 = b1.get("notificationId") or b1.get("notification_id")
    id2 = b2.get("notificationId") or b2.get("notification_id")
    assert id1 == id2, f"idempotency_key produced distinct notifications: {id1} != {id2}"
