"""Manual Path B driver for a SPECIFIC pre-registered user.

Drives: add meter (device key + meter->user) -> signed telemetry ingest ->
verify reading lands in zone stream -> poll on-chain GRID mint delta.

Run from tests/e2e with:
  REDIS_URL=redis://localhost:7010 CHAIN_BRIDGE_INSECURE=true \
  ENERGY_TOKEN_MINT=<grid mint> PYTHONPATH=lib \
  .venv/bin/python manual_path_b.py <USER_ID> <WALLET>
"""
import datetime
import os
import sys
import time

import requests
import chain
import crypto
import redis_util

USER_ID = sys.argv[1]
OWNER = sys.argv[2]

ORACLE_REST = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
INGEST_URL = f"{ORACLE_REST}/v1/private-network/ingest"
GRID_SCALE = 1_000_000_000
SETTLE_TIMEOUT = float(os.getenv("E2E_SETTLE_TIMEOUT", "240"))
GRID_MINT = (os.getenv("ENERGY_TOKEN_MINT") or "").strip()


def closed_window_ts_ms() -> int:
    now = int(time.time())
    window = 15 * 60
    current_start = now - (now % window)
    return (current_start - 2 * window + 60) * 1000


def rest_payload(meter_id, generated_kwh, ts_ms, signature):
    dt = datetime.datetime.fromtimestamp(ts_ms / 1000, tz=datetime.timezone.utc)
    iso = dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return {
        "protocol": "dlms",
        "device_id": meter_id,
        "payload": {
            "device_id": meter_id,
            "timestamp": iso,
            "energy_generated": float(generated_kwh),
            "signature": signature,
        },
    }


def zone_total():
    c = redis_util.client()
    return sum(c.xlen(f"gridtokenx:events:zone_{i}") for i in range(10))


def main():
    print(f"== user_id={USER_ID}")
    print(f"== wallet ={OWNER}")
    print(f"== grid mint={GRID_MINT}")
    assert GRID_MINT, "set ENERGY_TOKEN_MINT"
    assert chain.reachable(), "Chain Bridge unreachable (need CHAIN_BRIDGE_INSECURE=true)"

    # --- Task 4: add meter (device key + meter->user mapping) ---
    priv, pub_hex = crypto.new_identity()
    meter = f"E2E-MANUAL-{int(time.time()*1000) % 1000000}"
    redis_util.register_device_key(meter, pub_hex)
    redis_util.register_meter(meter, USER_ID)
    print(f"\n[meter] {meter} registered  device_pubkey={pub_hex[:16]}..  -> user {USER_ID}")

    before = chain.token_balance_of(OWNER, GRID_MINT)
    print(f"[mint] GRID balance BEFORE = {before} ({before/GRID_SCALE:g} GRID)")

    # --- Task 5: send signed readings (20+20+10 = 50 kWh in one closed window) ---
    z_before = zone_total()
    base_ts = closed_window_ts_ms()
    total_kwh = 0
    for i, kwh in enumerate((20, 20, 10)):
        ts = base_ts + i * 30_000
        sig = crypto.sign_telemetry(priv, meter, kwh, ts)
        r = requests.post(INGEST_URL, json=rest_payload(meter, float(kwh), ts, sig), timeout=10)
        print(f"[reading {i}] kwh={kwh} ts={ts} -> HTTP {r.status_code} {r.text[:80]}")
        assert r.status_code in (200, 202), f"ingest rejected: {r.status_code} {r.text}"
        total_kwh += kwh
    time.sleep(2)
    z_after = zone_total()
    print(f"[data] zone-stream entries: {z_before} -> {z_after} (+{z_after - z_before}) — reading ingested + verified + disseminated")
    expected = total_kwh * GRID_SCALE

    # --- Task 6: poll on-chain GRID mint delta ---
    print(f"[mint] waiting up to {SETTLE_TIMEOUT:g}s for settlement tick -> NATS -> Chain Bridge mint ...")
    deadline = time.time() + SETTLE_TIMEOUT
    after = before
    while time.time() < deadline:
        try:
            after = chain.token_balance_of(OWNER, GRID_MINT)
        except Exception:
            after = before
        if after > before:
            break
        time.sleep(5)

    print(f"[mint] GRID balance AFTER = {after} ({after/GRID_SCALE:g} GRID)  delta={after-before} (expected {expected})")
    if after == before:
        print("RESULT: NO MINT within timeout — check aggregator log for settlement/Chain Bridge errors")
        sys.exit(2)
    if after - before == expected:
        print(f"RESULT: ✅ EXACT mint — {total_kwh} kWh -> {expected/GRID_SCALE:g} GRID credited to {OWNER}")
    else:
        print(f"RESULT: ⚠️ mint delta {after-before} != expected {expected}")
        sys.exit(3)


if __name__ == "__main__":
    main()
