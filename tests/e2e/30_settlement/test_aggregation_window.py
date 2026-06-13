"""Suite 30 — 15-minute aggregation-window correctness (E2E_IMPL_PLAN line 59).

The settlement aggregator floors every reading's timestamp to a 15-minute window
(`aggregator.rs::get_window_start`, `WINDOW_MINUTES=15`) and accumulates energy into
one per-(meter, window) `BillingBin`. The in-crate unit tests cover the floor math;
this asserts the LIVE service does it end-to-end, observed via the durable bin store
(`gridtokenx:settlement:bins`, write-through in `zone_ingester` → `bin_store.persist`):

  - two readings in the SAME window  → ONE bin, reading_count==2, energy summed
  - the window start is FLOORED to the quarter hour (minute % 15 == 0, secs/nanos 0)
    and end == start + 15 min
  - a reading in a DIFFERENT window  → a SEPARATE bin

Timing: the two "current window" readings sit in the still-open window (end_time >
now → never eligible to settle). The third uses a FUTURE window (end far ahead), so
it can't settle mid-test either. `SETTLEMENT_GRACE_SECS` (default 120) is an extra
cushion: a just-closed window isn't settled for 120 s. The REST path has no
replay/freshness gate (replay-reject is deferred — see plan line 58), so a
future-dated reading is accepted and floored normally.

Ingest is gated by `api_key_auth` — send the harness key (`e2e-test-key`).

Run: cd tests/e2e && python -m pytest 30_settlement/test_aggregation_window.py -v
Skips gracefully if Oracle / Redis are unreachable.
"""
import datetime
import os
import time

import pytest
import requests

import crypto
import redis_util

ORACLE_REST = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
INGEST_URL = f"{ORACLE_REST}/v1/private-network/ingest"
API_KEY = os.getenv("AGGREGATOR_API_KEY", "e2e-test-key")
HEADERS = {"X-API-KEY": API_KEY}
WINDOW_MIN = 15
USER_ID = "00000000-0000-0000-0000-000000000001"


def _oracle_up() -> bool:
    try:
        requests.get(f"{ORACLE_REST}/health", timeout=3)
        return True
    except Exception:
        return False


def _redis_up() -> bool:
    try:
        redis_util.client().ping()
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(
    not (_oracle_up() and _redis_up()),
    reason="Oracle Bridge REST or Redis unreachable",
)


@pytest.fixture
def device():
    pk, pub_hex = crypto.new_identity()
    meter_id = f"E2E-WINDOW-{int(time.time() * 1000) % 1000000}"
    redis_util.register_device_key(meter_id, pub_hex)
    redis_util.register_meter(meter_id, USER_ID)
    yield {"meter_id": meter_id, "priv": pk}
    redis_util.delete_settlement_bins(meter_id)
    redis_util.unregister_device(meter_id)


def _floor_window(dt: datetime.datetime) -> datetime.datetime:
    return dt.replace(minute=(dt.minute // WINDOW_MIN) * WINDOW_MIN, second=0, microsecond=0)


def _ingest(device, *, when: datetime.datetime, generated: float, consumed: float):
    """Ingest one signed DLMS reading dated `when`. Signs over `kwh` (the canonical
    sign-value); `energy_generated`/`energy_consumed` feed the bin accumulation."""
    when = when.replace(microsecond=0)
    ts_ms = int(when.timestamp()) * 1000
    kwh = consumed  # arbitrary signed scalar; bin uses energy_* fields, not kwh
    sig = crypto.sign_telemetry(device["priv"], device["meter_id"], kwh, ts_ms)
    body = {
        "protocol": "dlms",
        "device_id": device["meter_id"],
        "payload": {
            "device_id": device["meter_id"],
            "timestamp": when.isoformat(),
            "kwh": kwh,
            "energy_generated": float(generated),
            "energy_consumed": float(consumed),
            "signature": sig,
        },
    }
    r = requests.post(INGEST_URL, json=body, headers=HEADERS, timeout=5)
    assert r.status_code in (200, 202), f"reading rejected: {r.status_code} {r.text}"


def _bin_at(bins, start_dt: datetime.datetime):
    """Find the bin whose start_time equals `start_dt` (compared at second res)."""
    want = start_dt.replace(microsecond=0).isoformat()
    for b in bins:
        st = datetime.datetime.fromisoformat(b["start_time"].replace("Z", "+00:00"))
        if st.replace(microsecond=0).isoformat() == want:
            return b
    return None


def _num(v) -> float:
    # BillingBin energy is rust_decimal::Decimal — may serialize as number or string.
    return float(str(v))


def test_window_floor_accumulate_and_separate(device):
    now = datetime.datetime.now(datetime.timezone.utc)
    cur_start = _floor_window(now)
    # Two readings in the current (still-open) window — must merge into one bin.
    t1 = cur_start + datetime.timedelta(minutes=2)
    t2 = cur_start + datetime.timedelta(minutes=5)
    # One reading in a future window (end far ahead → never settles mid-test).
    next_start = cur_start + datetime.timedelta(minutes=WINDOW_MIN)
    t3 = next_start + datetime.timedelta(minutes=2)

    _ingest(device, when=t1, generated=2.0, consumed=1.0)
    _ingest(device, when=t2, generated=3.0, consumed=0.5)
    _ingest(device, when=t3, generated=5.0, consumed=2.0)

    # Bin persistence is async (stream → zone_ingester → write-through), and the two
    # current-window readings are consumed independently — poll until the current bin
    # has accumulated BOTH (count==2) and the next-window bin exists, not just until
    # the bins first appear (else we'd race a half-accumulated bin).
    bins = []
    for _ in range(80):
        bins = redis_util.settlement_bins(device["meter_id"])
        cur = _bin_at(bins, cur_start)
        if cur and cur.get("reading_count") == 2 and _bin_at(bins, next_start):
            break
        time.sleep(0.25)

    cur = _bin_at(bins, cur_start)
    nxt = _bin_at(bins, next_start)
    assert cur is not None, f"current-window bin (start={cur_start.isoformat()}) absent: {bins}"
    assert nxt is not None, f"next-window bin (start={next_start.isoformat()}) absent: {bins}"

    # Same-window accumulation: two readings merged.
    assert cur["reading_count"] == 2, f"expected 2 readings in current bin, got {cur}"
    assert _num(cur["energy_generated"]) == pytest.approx(5.0), cur   # 2.0 + 3.0
    assert _num(cur["energy_consumed"]) == pytest.approx(1.5), cur    # 1.0 + 0.5

    # Window floor: start snaps to the quarter hour; end = start + 15 min.
    st = datetime.datetime.fromisoformat(cur["start_time"].replace("Z", "+00:00"))
    en = datetime.datetime.fromisoformat(cur["end_time"].replace("Z", "+00:00"))
    assert st.minute % WINDOW_MIN == 0 and st.second == 0 and st.microsecond == 0, (
        f"start not floored to quarter hour: {cur['start_time']}"
    )
    assert en - st == datetime.timedelta(minutes=WINDOW_MIN), (
        f"end != start + 15 min: {cur['start_time']} .. {cur['end_time']}"
    )

    # Separation: the future-window reading is its own bin, not merged.
    assert nxt["reading_count"] == 1, f"next-window bin should hold 1 reading, got {nxt}"
    assert _num(nxt["energy_generated"]) == pytest.approx(5.0), nxt
    assert st != datetime.datetime.fromisoformat(nxt["start_time"].replace("Z", "+00:00")), (
        "current and next bins must have distinct window starts"
    )
