"""30_settlement suite fixtures.

Suite-end residue sweep: each test purges its own meters, but the bridge
settles billing bins from *memory* (peek_completed_bins), so a mint-outbox
entry can be enqueued AFTER the test's cleanup ran — the per-test purge
races the settlement sweep (BILLING_FLUSH_INTERVAL_SECS). This finalizer
re-purges every serial created this session until two consecutive sweeps
find nothing, so an e2e run leaves no unmintable fake-wallet entries
retrying on a shared stack.
"""
import time

import pytest

import redis_util
import settlement_ingest

# Two clean sweeps this far apart outlast one flush interval (compose sets
# BILLING_FLUSH_INTERVAL_SECS=5; upstream default 30 is covered by the cap).
SWEEP_GAP_SECS = 7
MAX_WAIT_SECS = 45


@pytest.fixture(scope="session", autouse=True)
def _purge_settlement_residue_at_suite_end():
    yield
    serials = settlement_ingest.created_serials()
    if not serials:
        return
    deadline = time.time() + MAX_WAIT_SECS
    clean_sweeps = 0
    while clean_sweeps < 2 and time.time() < deadline:
        found = False
        for s in serials:
            c = redis_util.client()
            for key in (
                "gridtokenx:billing:mint_outbox",
                "gridtokenx:billing:mint_outbox:parked",
                "gridtokenx:billing:bins",
            ):
                fields = [
                    f for f in c.hscan_iter(key, match=f"{s}:*", no_values=True)
                ]
                if fields:
                    c.hdel(key, *fields)
                    found = True
        clean_sweeps = 0 if found else clean_sweeps + 1
        if clean_sweeps < 2:
            time.sleep(SWEEP_GAP_SECS)
