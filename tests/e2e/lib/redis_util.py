"""GridTokenX E2E — Redis helpers for Oracle device registry + dissemination asserts.

Key schemes (confirmed in gridtokenx-aggregator-bridge):
  device pubkey   : gridtokenx:devices:{meter_id}:pubkey   = <hex pubkey>
  meter -> user   : gridtokenx:meters:{serial}:user_id     = <uuid>
  dissemination   : gridtokenx:events:zone_{idx}           = Redis Stream (XADD)
"""
import json
import os
from typing import Optional

import redis

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:7010")


def client():
    return redis.from_url(REDIS_URL, decode_responses=True)


def register_device_key(meter_id: str, pubkey_hex: str):
    """Register Ed25519 device pubkey so Oracle accepts its signatures."""
    client().set(f"gridtokenx:devices:{meter_id}:pubkey", pubkey_hex)


def register_enckey(meter_id: str, enckey_hex: str):
    """Register the per-device AES-256 key (64-char hex = 32 bytes) the bridge
    fetches to decrypt secure-v4 DLMS frames (DeviceKeyRegistry.get_device_aes_key)."""
    client().set(f"gridtokenx:devices:{meter_id}:enckey", enckey_hex)


def unregister_enckey(meter_id: str):
    client().delete(f"gridtokenx:devices:{meter_id}:enckey")


def register_meter(serial: str, user_id: str, wallet: Optional[str] = None):
    """Map meter serial -> user_id for settlement resolution. When `wallet` is
    given, also set the owner wallet the surplus-mint flush loop resolves at
    `gridtokenx:meters:{serial}:wallet` (MeterRegistry.resolve_wallet)."""
    c = client()
    c.set(f"gridtokenx:meters:{serial}:user_id", user_id)
    if wallet:
        c.set(f"gridtokenx:meters:{serial}:wallet", wallet)


def unregister_device(meter_id: str):
    c = client()
    c.delete(f"gridtokenx:devices:{meter_id}:pubkey")
    c.delete(f"gridtokenx:meters:{meter_id}:user_id")
    c.delete(f"gridtokenx:meters:{meter_id}:wallet")


def stream_total_len(pattern: str = "gridtokenx:events:zone_*") -> int:
    """Sum XLEN across all zone streams — used to assert dissemination fan-out.

    NOTE: prefer `max_zone_stream_id` / `wait_zone_stream_advanced` for dissemination
    asserts. Total length goes flat once a stream hits its producer-side XADD MAXLEN
    cap (REDIS_STREAM_MAXLEN, aggregator commit 5a8e6b6) — appends then trim the oldest,
    so `len > before` can never be observed at saturation."""
    c = client()
    total = 0
    for key in c.scan_iter(match=pattern):
        try:
            total += c.xlen(key)
        except redis.exceptions.ResponseError:
            pass  # not a stream
    return total


def max_zone_stream_id(pattern: str = "gridtokenx:events:zone_*") -> tuple:
    """Largest (ms, seq) entry id across all zone streams, or (0, 0).

    A MAXLEN-safe dissemination progress marker: a new XADD advances the stream id
    monotonically even when the cap trims older entries (so it works where
    `stream_total_len` saturates), and it needs NO plaintext payload — zone-stream
    entries are encrypted at rest (`{"enc": {...}}`) so per-device matching isn't
    possible on a secure stack."""
    import time as _t
    c = client()
    mx = (0, 0)
    for key in c.scan_iter(match=pattern):
        try:
            ents = c.xrevrange(key, count=1)
        except redis.exceptions.ResponseError:
            continue  # not a stream
        if ents:
            ms, _, seq = ents[0][0].partition("-")
            cur = (int(ms), int(seq or 0))
            if cur > mx:
                mx = cur
    return mx


def wait_zone_stream_advanced(before: tuple, timeout: float = 12.0,
                              pattern: str = "gridtokenx:events:zone_*") -> bool:
    """Wait until a new zone-stream entry is appended past `before` (id advanced)."""
    import time as _t
    deadline = _t.time() + timeout
    while _t.time() < deadline:
        try:
            if max_zone_stream_id(pattern) > before:
                return True
        except Exception:
            pass
        _t.sleep(0.5)
    return False


def find_disseminated_reading(device_id: str, count: int = 200,
                              pattern: str = "gridtokenx:events:zone_*"):
    """Return the most recent disseminated `payload` (a `DeviceReading`) for
    `device_id`, or None.

    Each zone stream entry is `{"event": <json>}` where the JSON envelope is
    `{event_type, payload: DeviceReading}` (router.rs:91-103 disseminate). We tail
    each zone stream and return the newest payload whose `device_id` matches — lets
    a test assert the decoded energy values, not just stream growth.
    """
    c = client()
    best = None  # (stream_id, payload)
    for key in c.scan_iter(match=pattern):
        try:
            entries = c.xrevrange(key, count=count)
        except redis.exceptions.ResponseError:
            continue  # not a stream
        for stream_id, fields in entries:
            raw = fields.get("event")
            if not raw:
                continue
            try:
                payload = json.loads(raw).get("payload")
            except (ValueError, TypeError):
                continue
            if payload and payload.get("device_id") == device_id:
                if best is None or stream_id > best[0]:
                    best = (stream_id, payload)
    return best[1] if best else None
