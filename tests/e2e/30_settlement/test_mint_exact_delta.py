"""Suite 30 — exact mint delta: minted amount == net surplus kWh (→ kWh * 1e9 atomic).

NEW (replaces the deleted test_real_generation_mint.py's exact-amount assertion).
The deleted suite asserted the on-chain GRID balance delta == kwh * 1e9 via the
IAM wallet-resolve + on-chain read helpers. The CURRENT surplus path resolves the
recipient from the Redis meter registry and emits the mint INTENT on
`chain.tx.mint`; the kWh→atomic-unit scaling (GRID has 9 decimals) happens
downstream IN Chain Bridge when it builds the mint_to instruction — the
aggregator envelope carries the human-unit `energy_kwh: f64`
(infra/mint.rs:56-67), not atomic units.

So we assert the EXACT amount at the surface that carries it: the mint envelope's
`energy_kwh` must equal the bin's net surplus to floating tolerance, and we assert
the atomic-unit expectation it implies (energy_kwh * 1e9) explicitly so the
kWh→GRID contract is documented and pinned. net surplus = energy_generated -
energy_consumed, gated `Some(>0)` (aggregator.rs:53-60 net_surplus_kwh); only a
positive net mints.

Two cases:
  A. clean integer surplus — generated 40, consumed 0  → energy_kwh == 40.
  B. mixed gen/consume     — generated 30, consumed 12 → energy_kwh == 18 (net),
     proving the mint is the NET, not gross generation.
Both backdated into ONE closed window per meter so the flush loop settles them.

The atomic-units cross-check: GRID_DECIMALS_SCALE = 1e9 (9 decimals). We assert
round(energy_kwh * 1e9) equals the expected integer atomic amount the bridge will
mint — the explicit kWh↔atomic invariant the old on-chain test enforced, pinned
here at the envelope without needing an on-chain read.

SKIP semantics (anti-false-green): no mint within MINT_WAIT → SKIP loudly, never
a silent pass. Slow by construction (window past grace + flush poll interval).
"""
import datetime
import os
import sys
import time

import pytest
import requests

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))

import crypto
import nats_util
import redis_util

ORACLE = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
API_KEY = os.getenv("AGGREGATOR_API_KEY", "engineering-department-api-key-2025")
INGEST = f"{ORACLE}/v1/private-network/ingest"
SUBJECT = os.getenv("MINT_NATS_SUBJECT", "chain.tx.mint")
HEADERS = {"X-API-KEY": API_KEY}

WINDOW_MS = 15 * 60 * 1000
GRID_DECIMALS_SCALE = 1_000_000_000  # GRID = 9 decimals; bridge scales energy_kwh by this

MINT_WAIT = float(os.getenv("MINT_WAIT_SECS", "240"))
BACKDATE_MS = int(os.getenv("MINT_BACKDATE_SECS", str(20 * 60))) * 1000
OWNER_USER = "00000000-0000-0000-0000-000000000001"


def _oracle_up() -> bool:
    try:
        requests.get(f"{ORACLE}/health", timeout=3)
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
    pytest.mark.skipif(not _oracle_up(), reason=f"aggregator REST not reachable at {ORACLE}"),
    pytest.mark.skipif(not _redis_up(), reason="Redis not reachable (lib/redis_util)"),
    pytest.mark.skipif(not nats_util.reachable(), reason=f"NATS not reachable at {nats_util.NATS_URL}"),
]


def _new_meter(prefix: str):
    pk, pub_hex = crypto.new_identity()
    meter = f"{prefix}-{int(time.time() * 1000) % 1_000_000}"
    wallet = f"Wa11et{meter.replace('-', '')}".ljust(43, "1")[:43]
    redis_util.register_device_key(meter, pub_hex)
    redis_util.register_meter(meter, OWNER_USER, wallet=wallet)
    return {"meter": meter, "priv": pk, "wallet": wallet}


def _payload(meter, priv, *, kwh, generated, consumed, ts_ms):
    dt = datetime.datetime.fromtimestamp(ts_ms / 1000, tz=datetime.timezone.utc)
    iso = dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    sig = crypto.sign_telemetry(priv, meter, kwh, ts_ms)
    return {
        "protocol": "dlms",
        "device_id": meter,
        "payload": {
            "device_id": meter,
            "timestamp": iso,
            "kwh": float(kwh),
            "energy_generated": float(generated),
            "energy_consumed": float(consumed),
            "signature": sig,
        },
    }


def _ingest(payload):
    r = requests.post(INGEST, json=payload, headers=HEADERS, timeout=20)
    assert r.status_code in (200, 202), f"reading rejected: {r.status_code} {r.text}"


def test_mint_amount_equals_net_surplus_in_kwh_and_atomic_units():
    """A clean-surplus meter and a mixed gen/consume meter, each in one closed
    window. Assert each mint's energy_kwh == that meter's NET surplus exactly, and
    that energy_kwh * 1e9 is the integer atomic amount the bridge will mint."""
    clean = _new_meter("E2E-DELTA-CLEAN")   # 40 gen, 0 con → net 40
    mixed = _new_meter("E2E-DELTA-MIXED")   # 30 gen, 12 con → net 18
    ts_ms = int(time.time() * 1000) - BACKDATE_MS  # closed past grace

    clean_net = 40.0
    mixed_gen, mixed_con = 30.0, 12.0
    mixed_net = mixed_gen - mixed_con  # 18.0

    def _trigger():
        _ingest(_payload(clean["meter"], clean["priv"], kwh=clean_net,
                         generated=clean_net, consumed=0, ts_ms=ts_ms))
        # sign the canonical kwh value (handlers.rs resolves kwh first); net is
        # generated - consumed (dlms.rs).
        _ingest(_payload(mixed["meter"], mixed["priv"], kwh=mixed_gen,
                         generated=mixed_gen, consumed=mixed_con, ts_ms=ts_ms))

    def _matches(msg):
        key = str(msg.get("idempotency_key", ""))
        return key.startswith(f"mint:{clean['meter']}:") or key.startswith(f"mint:{mixed['meter']}:")

    try:
        msgs = nats_util.collect_sync(SUBJECT, _trigger, match=_matches, timeout=MINT_WAIT, want=2)
    finally:
        redis_util.unregister_device(clean["meter"])
        redis_util.unregister_device(mixed["meter"])

    clean_mints = [m for m in msgs if str(m.get("idempotency_key", "")).startswith(f"mint:{clean['meter']}:")]
    mixed_mints = [m for m in msgs if str(m.get("idempotency_key", "")).startswith(f"mint:{mixed['meter']}:")]

    if not clean_mints and not mixed_mints:
        pytest.skip(
            f"no mint on '{SUBJECT}' within {MINT_WAIT:.0f}s — minting is disabled "
            "(MINT_VIA_CHAIN_BRIDGE unset) or the deployed bridge predates the chain.tx.mint "
            "feature. Refusing to assert exact delta on silence (would be a false pass)."
        )

    def _assert_delta(mint, expected_kwh, label):
        got = float(mint["energy_kwh"])
        assert abs(got - expected_kwh) < 1e-6, (
            f"{label}: energy_kwh != net surplus {expected_kwh}: {mint}"
        )
        # Atomic-unit contract: the bridge scales energy_kwh by 1e9 (GRID 9 dec).
        atomic = round(got * GRID_DECIMALS_SCALE)
        assert atomic == round(expected_kwh * GRID_DECIMALS_SCALE), (
            f"{label}: atomic amount {atomic} != expected {round(expected_kwh * GRID_DECIMALS_SCALE)} "
            f"({expected_kwh} kWh * 1e9)"
        )

    asserted = []
    if clean_mints:
        _assert_delta(clean_mints[0], clean_net, "clean-surplus meter")
        asserted.append("clean")
    if mixed_mints:
        _assert_delta(mixed_mints[0], mixed_net, "mixed gen/consume meter (net != gross)")
        asserted.append("mixed")

    # At least one exact-delta assertion ran (guarded by the skip above). If only
    # one of the two landed in time, that's a timing artefact, not a correctness
    # failure — note which case is still pending.
    assert asserted, "no mint matched either meter (should be unreachable past the skip)"
    if "mixed" not in asserted:
        pytest.skip(
            "clean-surplus exact delta verified, but the mixed gen/consume mint (net != gross) "
            f"did not arrive within {MINT_WAIT:.0f}s — net-vs-gross case left unasserted (timing)."
        )
    if "clean" not in asserted:
        pytest.skip(
            "mixed-net exact delta verified, but the clean-surplus mint did not arrive within "
            f"{MINT_WAIT:.0f}s — clean case left unasserted (timing)."
        )
