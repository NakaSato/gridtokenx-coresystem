"""GridTokenX E2E — Redis helpers for Oracle device registry + dissemination asserts.

Key schemes (confirmed in gridtokenx-aggregator-bridge):
  device pubkey   : gridtokenx:devices:{meter_id}:pubkey   = <hex pubkey>
  meter -> user   : gridtokenx:meters:{serial}:user_id     = <uuid>
  dissemination   : gridtokenx:events:zone_{idx}           = Redis Stream (XADD)
"""
import json
import os
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


def register_meter(serial: str, user_id: str):
    """Map meter serial -> user_id for settlement resolution."""
    client().set(f"gridtokenx:meters:{serial}:user_id", user_id)


def unregister_device(meter_id: str):
    client().delete(f"gridtokenx:devices:{meter_id}:pubkey")


def stream_total_len(pattern: str = "gridtokenx:events:zone_*") -> int:
    """Sum XLEN across all zone streams — used to assert dissemination fan-out."""
    c = client()
    total = 0
    for key in c.scan_iter(match=pattern):
        try:
            total += c.xlen(key)
        except redis.exceptions.ResponseError:
            pass  # not a stream
    return total


SETTLEMENT_BINS_HASH = "gridtokenx:settlement:bins"


def settlement_bins(meter_serial: str):
    """Return the persisted `BillingBin`s for `meter_serial`.

    The settlement aggregator write-throughs each per-(meter, 15-min-window) bin to
    the Redis hash `gridtokenx:settlement:bins` (bin_store.rs `BINS_HASH`), field
    `{meter_id}:{window_start_ms}`, value a JSON `BillingBin` (aggregator.rs:16-25).
    Lets a test assert window-floor / accumulation on the LIVE service. Filters by
    `meter_serial` so a per-run unique serial isolates this test's bins.
    """
    c = client()
    out = []
    for field, value in c.hgetall(SETTLEMENT_BINS_HASH).items():
        try:
            bin_ = json.loads(value)
        except (ValueError, TypeError):
            continue
        if bin_.get("meter_serial") == meter_serial:
            bin_["_field"] = field
            out.append(bin_)
    return out


def delete_settlement_bins(meter_serial: str):
    """HDEL this meter's bins so the test doesn't leave a partial bin that later
    settles (mints) or pollutes other suites."""
    c = client()
    fields = [b["_field"] for b in settlement_bins(meter_serial) if b.get("_field")]
    if fields:
        c.hdel(SETTLEMENT_BINS_HASH, *fields)


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
