"""Suite 30 — settlement idempotency: same (meter, window) carries one dedup key.

RESTORED & ADAPTED. The original suite (deleted on this branch) asserted the
on-chain exactly-once guard by reading the user's GRID balance before/after a
replay (round 1 mints, round 2 must NOT raise the balance). That required the
IAM gRPC wallet-resolve path and an on-chain read helper. The CURRENT surplus
path resolves the recipient from the Redis meter registry
(`gridtokenx:meters:{serial}:wallet`) and mints over `chain.tx.mint` — and,
critically, the aggregator itself does NOT suppress a re-mint:

  The settlement flush loop SNAPSHOTS completed bins and EVICTS them in the same
  locked section (`src/main.rs:261-270` peek_completed_bins → remove_bins), then
  fires the mint fire-and-forget. So re-ingesting the same (meter, window) AFTER
  that flush re-creates a fresh in-memory bin and the loop publishes a SECOND
  `chain.tx.mint` envelope. The exactly-once guarantee is NOT in the aggregator —
  it is the bridge's replay dedup on `idempotency_key` plus the on-chain
  `(meter_id, window_start_ms)` gen_mint PDA backstop.

What is therefore observable (and asserted) at the NATS edge — the only surface
we can watch without the IAM/on-chain helpers — is the DEDUP TOKEN itself:

  every mint envelope for the same (meter, window) carries the SAME
  idempotency_key `mint:{serial}:{window_start_ms}` and the SAME window_start_ms
  (infra/mint.rs:24-25, 56-67). That stable key is exactly what lets the bridge
  collapse replays to one on-chain mint. If the key drifted across a replay, the
  bridge could not dedup and a double-mint would slip through — so this is the
  meaningful, layer-appropriate invariant for this observation point.

We send the SAME serial into the SAME closed window TWICE and assert: at least
one mint is observed, and ALL observed mints share one idempotency_key +
window_start_ms + energy_kwh. (The actual balance-unchanged-on-replay assertion
lives on-chain, behind the bridge consuming this key — out of scope for a
NATS-only observation; documented here rather than silently dropped.)

SKIP semantics (anti-false-green): if NO mint arrives within MINT_WAIT, SKIP
loudly rather than pass — minting may be disabled or the bridge may predate the
feature. Slow by construction (window must close past grace; flush loop polls).

Ingest is an encrypted DLMS v4 frame over gRPC BulkRawIngest (lib/settlement_ingest)
so the test runs on dev AND secure stacks — plaintext REST is 426 under secure mode.
The frame build is deterministic (nonce derives from manuf++ts_sec++ver), so re-sending
the same (meter, ts_sec, energy) is a byte-identical replay — the scenario under test.
"""
import os
import sys
import time

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))

import nats_util
import redis_util
import settlement_ingest

SUBJECT = os.getenv("MINT_NATS_SUBJECT", "chain.tx.mint")

WINDOW_MS = 15 * 60 * 1000

MINT_WAIT = float(os.getenv("MINT_WAIT_SECS", "150"))
BACKDATE_MS = int(os.getenv("MINT_BACKDATE_SECS", str(20 * 60))) * 1000
# Gap between the two replay ingests — long enough that a flush loop tick can fire
# between them so the second ingest hits a fresh post-eviction bin (the realistic
# replay). Default ~1.2x BILLING_FLUSH_INTERVAL_SECS (30) for a likely re-publish.
REPLAY_GAP = float(os.getenv("MINT_REPLAY_GAP_SECS", "40"))
OWNER_USER = "00000000-0000-0000-0000-000000000001"


def _redis_up() -> bool:
    try:
        redis_util.client().ping()
        return True
    except Exception:
        return False


pytestmark = [
    pytest.mark.skipif(
        not settlement_ingest.grpc_up(),
        reason=f"aggregator gRPC not reachable at {settlement_ingest.ORACLE_GRPC}",
    ),
    pytest.mark.skipif(not _redis_up(), reason="Redis not reachable (lib/redis_util)"),
    pytest.mark.skipif(not nats_util.reachable(), reason=f"NATS not reachable at {nats_util.NATS_URL}"),
]


def test_same_window_replay_uses_stable_idempotency_key():
    """Ingest the SAME (serial, closed window) reading twice; every resulting
    mint envelope must carry the SAME dedup token (idempotency_key +
    window_start_ms + energy_kwh). That stable key is what the bridge / on-chain
    PDA collapse to exactly one mint — the durable exactly-once backstop."""
    m = settlement_ingest.new_meter("I", OWNER_USER)
    stub = settlement_ingest.stub()
    ts_sec = (int(time.time() * 1000) - BACKDATE_MS) // 1000  # closed past grace
    kwh = 25.0  # pure surplus → net 25

    def _trigger():
        settlement_ingest.ingest(stub, m, generated=kwh, consumed=0, ts_sec=ts_sec)
        # Let a flush tick fire + evict so the replay re-creates the bin (the real
        # replay scenario the bridge dedup must absorb), then re-send the identical
        # frame (same meter/ts_sec/energy → byte-identical, see module docstring).
        time.sleep(REPLAY_GAP)
        settlement_ingest.ingest(stub, m, generated=kwh, consumed=0, ts_sec=ts_sec)

    def _matches(msg):
        return str(msg.get("idempotency_key", "")).startswith(f"mint:{m['meter']}:")

    try:
        # Watch long enough for both ingests + their flush ticks. want=2 so we
        # collect a replay envelope if one is published, without hard-requiring it.
        timeout = MINT_WAIT + REPLAY_GAP
        msgs = nats_util.collect_sync(SUBJECT, _trigger, match=_matches, timeout=timeout, want=2)
    finally:
        settlement_ingest.cleanup(m)

    if not msgs:
        pytest.skip(
            f"no mint on '{SUBJECT}' within {MINT_WAIT + REPLAY_GAP:.0f}s for {m['meter']} — "
            "minting is disabled (MINT_VIA_CHAIN_BRIDGE unset) or the deployed bridge predates "
            "the chain.tx.mint feature. Refusing to assert idempotency on silence (false pass)."
        )

    # The window is fixed (single backdated timestamp), so EVERY observed mint for
    # this meter — first or replay — must share one dedup token. Drift here would
    # defeat the bridge's replay dedup and let a double-mint through.
    keys = {str(msg["idempotency_key"]) for msg in msgs}
    windows = {int(msg["window_start_ms"]) for msg in msgs}
    energies = {round(float(msg["energy_kwh"]), 6) for msg in msgs}

    assert len(keys) == 1, f"replay must reuse ONE idempotency_key, saw {keys}"
    assert len(windows) == 1, f"replay must map to ONE window_start_ms, saw {windows}"

    key = next(iter(keys))
    ws = next(iter(windows))
    assert key == f"mint:{m['meter']}:{ws}", f"idempotency_key not mint:serial:window: {key}"
    assert ws % WINDOW_MS == 0, f"window_start_ms not floored to 15-min grid: {ws}"

    # Same single reading each round → identical surplus, so identical energy_kwh.
    assert len(energies) == 1 and abs(next(iter(energies)) - kwh) < 1e-6, (
        f"replay mints must carry identical energy_kwh == {kwh}, saw {energies}"
    )

    if len(msgs) < 2:
        # Only the first mint landed (no replay envelope republished in time — the
        # bridge may have already settled/evicted, or the tick timing missed). The
        # stable-key invariant is verified on what we DID see; we can't observe the
        # second mint to compare, so note it rather than fake-asserting a replay.
        pytest.skip(
            "only one mint envelope observed; replay envelope not seen in time — the "
            "stable idempotency-key shape is verified, but the second-mint comparison "
            "could not be made (timing). Not a failure."
        )
