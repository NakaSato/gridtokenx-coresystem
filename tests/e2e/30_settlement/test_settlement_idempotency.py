"""Settlement idempotency — same (meter, window) is never double-minted.

Closes the E2E_IMPL_PLAN Phase 4 item "Settlement idempotency: same window not
double-minted". The exactly-once guard is on-chain: the Energy Token program's
`gen_mint` record PDA, seeded `[b"gen_mint", meter_id, window_start_ms]`
(`blockchain-core/src/rpc/instructions.rs` gen_mint_record_pda), created
`init_if_needed` on the first mint and found-and-no-op on replay. `meter_id` is
deterministic from the serial — `Uuid::new_v5(NAMESPACE_OID, serial)`
(zone_ingester.rs:508) — so re-sending the same serial into the same 15-min
window re-derives the same PDA and the second mint is a no-op (also short-cut by
the bridge's Redis settled-marker fast-path).

Flow:
  round 1: 3 signed readings in one closed window → settle → GRID balance += 50.
  round 2: the SAME serial + SAME window readings → settle attempt → the on-chain
           guard (or Redis marker) rejects the re-mint → balance UNCHANGED.

This is the end-to-end complement to the effect-level dedup unit/integration
tests (chain-bridge `claim_or_replay`): those guard concurrent/duplicate NATS
re-sends in-process; this proves the durable on-chain (meter, window) guard.

OPT-IN: same prerequisites as test_path_b_generation_mint.py — relaunch the
aggregator with MINT_VIA_CHAIN_BRIDGE=true (+ NATS_URL, IAM_SERVICE_URL=:5010
gRPC, CHAIN_BRIDGE_URL) and set E2E_MINT_VIA_CHAIN_BRIDGE=1.
"""
import datetime
import os
import sys
import time

import pytest
import requests

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))

import chain
import crypto
import redis_util

ORACLE_REST = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
INGEST_URL = f"{ORACLE_REST}/v1/private-network/ingest"
IAM_URL = os.getenv("IAM_URL", "http://localhost:4010")
API_KEY = os.getenv("GRIDTOKENX_API_KEY", "e2e-test-key")
INGEST_HEADERS = {"X-API-KEY": API_KEY}

GRID_DECIMALS_SCALE = 1_000_000_000  # GRID has 9 decimals
SETTLE_TIMEOUT = float(os.getenv("E2E_SETTLE_TIMEOUT", "180"))
# Round 2 must NOT mint. Wait through several 60s engine ticks before concluding
# the re-mint was correctly suppressed; poll for an (illegal) increase throughout.
NO_REMINT_WAIT = float(os.getenv("E2E_NO_REMINT_WAIT", "150"))


def _up(url: str) -> bool:
    try:
        requests.get(url, timeout=3)
        return True
    except Exception:
        return False


def _redis_up() -> bool:
    try:
        redis_util.client().ping()
        return True
    except Exception:
        return False


pytestmark = [
    pytest.mark.skipif(
        os.getenv("E2E_MINT_VIA_CHAIN_BRIDGE", "") != "1",
        reason="opt-in: relaunch aggregator with MINT_VIA_CHAIN_BRIDGE=true and set "
               "E2E_MINT_VIA_CHAIN_BRIDGE=1 — see module docstring",
    ),
    pytest.mark.skipif(
        not (_up(f"{IAM_URL}/health") and _up(f"{ORACLE_REST}/health") and _redis_up()),
        reason="IAM, aggregator-bridge REST, or Redis unreachable",
    ),
]


def _resolve_grid_mint() -> str:
    direct = (os.getenv("ENERGY_TOKEN_MINT") or os.getenv("GRID_MINT") or "").strip()
    if direct:
        return direct
    prog = (os.getenv("ENERGY_TOKEN_PROGRAM_ID")
            or os.getenv("SOLANA_ENERGY_TOKEN_PROGRAM_ID") or "").strip()
    if prog:
        try:
            return chain.grid_mint_pda(prog)
        except Exception:
            return ""
    return ""


def _closed_window_ts_ms() -> int:
    """Timestamp inside an already-closed 15-min window (two slots back, +60s)."""
    now = int(time.time())
    window = 15 * 60
    current_start = now - (now % window)
    return (current_start - 2 * window + 60) * 1000


def _rest_payload(meter_id: str, generated_kwh: float, ts_ms: int, signature: str):
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


WINDOW_KWH = 50


def _send_window(meter: str, priv, base_ts: int) -> int:
    """Send ONE 50 kWh reading into the window. Returns kWh sent.

    Deliberately a single reading, not several accumulating into the bin: the
    zone ingester consumes the stream asynchronously while the 60s engine tick
    peeks completed bins, so multiple readings can race — a tick that fires
    after only the first reading is consumed mints a partial amount and locks
    the (meter, window) gen_mint PDA, stranding the rest. One reading makes the
    minted amount deterministic so the idempotency assertion is exact."""
    sig = crypto.sign_telemetry(priv, meter, WINDOW_KWH, base_ts)
    r = requests.post(INGEST_URL, json=_rest_payload(meter, float(WINDOW_KWH), base_ts, sig),
                      headers=INGEST_HEADERS, timeout=10)
    assert r.status_code in (200, 202), f"ingest rejected: {r.status_code} {r.text}"
    return WINDOW_KWH


def _wait_for_increase(owner: str, mint: str, baseline: int, timeout: float) -> int:
    """Poll balance until it exceeds baseline or timeout; return last reading."""
    deadline = time.time() + timeout
    cur = baseline
    while time.time() < deadline:
        try:
            cur = chain.token_balance_of(owner, mint)
        except Exception:
            cur = baseline
        if cur > baseline:
            return cur
        time.sleep(5)
    return cur


def test_same_window_not_double_minted(new_user):
    grid_mint = _resolve_grid_mint()
    if not grid_mint:
        pytest.skip("GRID mint pubkey unresolvable (set ENERGY_TOKEN_MINT or ENERGY_TOKEN_PROGRAM_ID)")
    if not chain.reachable():
        pytest.skip("Chain Bridge unreachable over plain HTTP — start with CHAIN_BRIDGE_INSECURE=true")

    owner = new_user["wallet"]
    user_id = new_user["user_id"]
    assert owner and user_id, "new_user must provide linked wallet + user_id"

    priv, pub_hex = crypto.new_identity()
    meter = f"E2E-IDEMP-{int(time.time()*1000) % 1000000}"
    redis_util.register_device_key(meter, pub_hex)
    redis_util.register_meter(meter, user_id)

    try:
        base_ts = _closed_window_ts_ms()
        before = chain.token_balance_of(owner, grid_mint)

        # --- round 1: first settlement of (meter, window) must mint ---------
        total_kwh = _send_window(meter, priv, base_ts)
        expected = total_kwh * GRID_DECIMALS_SCALE
        after1 = _wait_for_increase(owner, grid_mint, before, SETTLE_TIMEOUT)
        assert after1 > before, (
            f"round 1 minted nothing within {SETTLE_TIMEOUT}s (before={before}) — "
            "check aggregator launched with MINT_VIA_CHAIN_BRIDGE=true"
        )
        assert after1 - before == expected, (
            f"round 1 delta mismatch: expected {expected} ({total_kwh} kWh * 1e9), got {after1 - before}"
        )

        # --- round 2: SAME serial + SAME window → must NOT mint again --------
        # Re-derives the same (meter_id, window_start) → same gen_mint PDA, which
        # already exists → the on-chain guard makes the re-mint a no-op.
        _send_window(meter, priv, base_ts)
        after2 = _wait_for_increase(owner, grid_mint, after1, NO_REMINT_WAIT)
        assert after2 == after1, (
            f"DOUBLE MINT: balance rose again on a replay of the same (meter, window) — "
            f"after round 1 = {after1}, after round 2 = {after2} (+{after2 - after1}). "
            "The on-chain gen_mint PDA / Redis settled-marker guard failed."
        )
    finally:
        redis_util.unregister_device(meter)
