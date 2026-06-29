#!/usr/bin/env python3
"""Force a signed surplus reading into the Aggregator Bridge to drive the mint leg.

Signs a backdated `+kwh` DLMS/COSEM reading (energy_generated=kwh, consumed=0) for an
ALREADY-CLAIMED meter and posts it to /v1/private-network/ingest. The timestamp is
floored into a 15-minute window that has already closed beyond the settlement grace
(default 120s), so the bridge's settlement sweep (every 30s) evicts the bin and fires
the surplus mint within ~30-40s instead of waiting up to the full window.

Prereqs: the meter must already be onboarded (IAM register→verify→claim via meter-service)
so the bridge resolves a non-nil owner + wallet — otherwise the mint is skipped. Run
`scripts/e2e_iam_flow.py --once` first and reuse its meter serial.

Run from gridtokenx-smartmeter-simulator/backend so the package imports resolve:
  AGGREGATOR_BRIDGE_URL=http://localhost:4030 REDIS_URL=redis://localhost:7010 \
    uv run python <this> --meter <SERIAL> --kwh 5 --zone 4

Secure-mode stacks (AGGREGATOR_REQUIRE_SECURE=true) refuse plaintext REST with 426 —
use an https URL + --encrypt, which seals the OBIS frame as an AES-256-GCM `dlms-enc`
envelope and presents the dev mTLS client cert automatically:
  AGGREGATOR_BRIDGE_URL=https://localhost:4030 REDIS_URL=redis://localhost:7010 \
    uv run python <this> --meter <SERIAL> --kwh 5 --zone 4 --encrypt
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.append(os.path.join(os.getcwd(), "src"))

from smart_meter_simulator.config import get_config  # noqa: E402
from smart_meter_simulator.models.reading import EnergyReading  # noqa: E402
from smart_meter_simulator.transport.aggregator_bridge import (  # noqa: E402
    AggregatorBridgeClient,
    MeterKey,
    register_enckeys_redis,
    register_pubkeys_redis,
)

WINDOW_MIN = 15  # must match the bridge's WINDOW_MINUTES
GRACE_S = 120  # must match BILLING_FLUSH_GRACE_SECS default


def _auto_mtls(bridge_url: str) -> dict:
    """mTLS kwargs for AggregatorBridgeClient when the bridge URL is https.

    Mirrors e2e_iam_flow.py: env (E2E_TLS_*) overrides; otherwise default to the dev
    certs the superproject ships under infra/certs/. Empty dict for plain http.
    """
    if not bridge_url.lower().startswith("https"):
        return {}
    crt = os.getenv("E2E_TLS_CERT")
    key = os.getenv("E2E_TLS_KEY")
    ca = os.getenv("E2E_TLS_CA")
    if not (crt and key):
        # this file: <root>/.claude/skills/telemetry-hops/scripts/force_surplus.py
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), *([".."] * 4)))
        certs = os.path.join(root, "infra", "certs")
        dc = os.path.join(certs, "clients", "smartmeter-simulator.crt")
        dk = os.path.join(certs, "clients", "smartmeter-simulator.key")
        dca = os.path.join(certs, "ca.crt")
        if os.path.exists(dc) and os.path.exists(dk):
            crt, key = dc, dk
            ca = ca or (dca if os.path.exists(dca) else None)
    if crt and key:
        return {"client_cert": (crt, key), "verify": ca if ca else False}
    return {}


def _completed_window_ts(now: datetime) -> datetime:
    """A timestamp inside the most recent 15-min window that is already past grace."""
    # Step back grace + one full window, then floor to the window boundary.
    t = now - timedelta(seconds=GRACE_S) - timedelta(minutes=WINDOW_MIN)
    floored_min = (t.minute // WINDOW_MIN) * WINDOW_MIN
    return t.replace(minute=floored_min, second=30, microsecond=0)


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--meter", required=True, help="claimed meter serial (UUID)")
    ap.add_argument("--kwh", type=float, default=5.0, help="surplus kWh to mint")
    ap.add_argument("--zone", type=int, default=4, help="zone_code for stream routing")
    ap.add_argument(
        "--at",
        default=None,
        help="ISO8601 UTC timestamp override (default: auto past-grace window)",
    )
    ap.add_argument(
        "--encrypt",
        action="store_true",
        help="seal as AES-256-GCM dlms-enc envelope (required when the bridge runs "
        "AGGREGATOR_REQUIRE_SECURE=true; use with an https AGGREGATOR_BRIDGE_URL)",
    )
    args = ap.parse_args()

    cfg = get_config()
    key = MeterKey(args.meter)
    # Idempotent: ensure the device pubkey is in the bridge's Redis registry so the
    # Ed25519 signature verifies even on a fresh validator/redis.
    register_pubkeys_redis(cfg.redis_url, [key])
    # Encrypted path also needs the per-device AES key in the bridge's enckey registry
    # so it can GCM-decrypt the envelope; register it idempotently.
    if args.encrypt:
        register_enckeys_redis(cfg.redis_url, [key])

    if args.at:
        ts = datetime.fromisoformat(args.at)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
    else:
        # now() unavailable under some sandboxes; derive from a fixed offset is fine
        # because the bridge bins on THIS timestamp, not wall-clock.
        ts = _completed_window_ts(datetime.now(timezone.utc))

    reading = EnergyReading(
        meter_id=args.meter,
        timestamp=ts,
        energy_generated=args.kwh,
        energy_consumed=0.0,
        surplus_energy=args.kwh,
        deficit_energy=0.0,
        interval_seconds=WINDOW_MIN * 60,
        voltage=232.0,
        frequency=50.0,
        power_factor=0.99,
        location="forced-surplus",
        meter_type="solar",
        user_type="prosumer",
    )

    client = AggregatorBridgeClient(
        base_url=cfg.aggregator_bridge_url,
        api_key=cfg.aggregator_api_key,
        **_auto_mtls(cfg.aggregator_bridge_url),
    )
    try:
        send_kwargs = {"zone_code": args.zone}
        if args.encrypt:
            # Monotonic invocation counter (anti-replay): wall-clock ms strictly
            # increases across runs, so re-forcing the same meter never replays.
            send_kwargs["encrypt"] = True
            send_kwargs["counter"] = int(datetime.now(timezone.utc).timestamp() * 1000)
        resp = await client.send_reading(reading, key, **send_kwargs)
    finally:
        await client.close()

    win = ts.replace(minute=(ts.minute // WINDOW_MIN) * WINDOW_MIN, second=0)
    print(
        f"ingest status={resp.status_code} meter={args.meter} "
        f"net_kwh=+{args.kwh} window_start={win.isoformat()} "
        f"(completed → mint sweep within ~{GRACE_S}s grace + 30s interval)"
    )
    return 0 if resp.status_code == 202 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
