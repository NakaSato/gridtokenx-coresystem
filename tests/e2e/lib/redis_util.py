"""GridTokenX E2E — Redis helpers for Oracle device registry + dissemination asserts.

Key schemes (confirmed in gridtokenx-aggregator-bridge):
  device pubkey   : gridtokenx:devices:{meter_id}:pubkey   = <hex pubkey>
  meter -> user   : gridtokenx:meters:{serial}:user_id     = <uuid>
  dissemination   : gridtokenx:events:zone_{idx}           = Redis Stream (XADD)
"""
import os
import redis

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:7010")


def client():
    return redis.from_url(REDIS_URL, decode_responses=True)


def register_device_key(meter_id: str, pubkey_hex: str):
    """Register Ed25519 device pubkey so Oracle accepts its signatures."""
    client().set(f"gridtokenx:devices:{meter_id}:pubkey", pubkey_hex)


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
