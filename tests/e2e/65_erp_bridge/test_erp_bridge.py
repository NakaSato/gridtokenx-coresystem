"""Suite 65 — ERP Bridge (:5050 HTTP admin/health surface).

Covers three things, in order of how much they matter:

1. **The safety gates are actually off.** Dry-run on, FI-CA posting off, REC
   issuance off. These are policy defaults with a legal review attached, and a
   deploy that silently flips one is the failure mode worth catching.
2. **The reconciliation engine classifies correctly end to end** — through the
   HTTP layer, the deferral lookup and the database write, not just in the unit
   tests. All five break classes plus the INCOMPLETE case.
3. **A missing ERP feed never renders as CLEAN.** Phase 1 has no read-back, so
   every real period is INCOMPLETE; if that ever reads as a passed check, the
   detective control is worse than useless.

Run: cd tests/e2e && python -m pytest 65_erp_bridge -v
"""
import os
import uuid

import pytest
import requests

BASE = os.getenv("ERP_BRIDGE_URL", "http://localhost:5050")
TIMEOUT = 8

# Well past the 0.01 kWh default scaler tolerance, so no assertion here is
# sensitive to rounding.
PERIOD_START = 1_700_000_000_000 - (1_700_000_000_000 % 900_000)
PERIOD_END = PERIOD_START + 30 * 24 * 3_600_000


def _up():
    try:
        return requests.get(f"{BASE}/health", timeout=3).status_code == 200
    except requests.RequestException:
        return False


pytestmark = pytest.mark.skipif(
    not _up(), reason=f"erp-bridge not reachable at {BASE} (run `just orb-up`)"
)


def pod():
    """A fresh PoD per case — verdicts are keyed (pod, period_start)."""
    return f"PoD-E2E-{uuid.uuid4().hex[:10]}"


def evaluate(pod_id, meter, chain, erp=None):
    body = {
        "period_start_ms": PERIOD_START,
        "period_end_ms": PERIOD_END,
        "meter_kwh": meter,
        "chain_kwh": chain,
    }
    if erp is not None:
        body["erp_kwh"] = erp
    r = requests.post(
        f"{BASE}/admin/recon/{pod_id}/evaluate", json=body, timeout=TIMEOUT
    )
    assert r.status_code == 200, f"{r.status_code}: {r.text}"
    return r.json()


# --------------------------------------------------------------------------
# 1. Gates
# --------------------------------------------------------------------------

def test_health_reports_the_service_and_its_adapter():
    r = requests.get(f"{BASE}/health", timeout=TIMEOUT)
    assert r.status_code == 200
    body = r.json()
    assert body["service"] == "erp-bridge"
    assert body["adapter"] in ("mock", "isu_idoc", "s4_odata")


def test_dry_run_is_on():
    """Phases 1-2 build and log documents; they never transmit."""
    assert requests.get(f"{BASE}/health", timeout=TIMEOUT).json()["dry_run"] is True


def test_fica_posting_is_disabled():
    """Flipping this is a business decision with a legal review attached."""
    body = requests.get(f"{BASE}/health", timeout=TIMEOUT).json()
    assert body["fica_posting_enabled"] is False


def test_rec_issuance_is_disabled():
    """Without a net-billing exclusion feed, anti-double-counting is advisory."""
    body = requests.get(f"{BASE}/health", timeout=TIMEOUT).json()
    assert body["rec_adapter_enabled"] is False


def test_ready_reflects_the_database_only():
    r = requests.get(f"{BASE}/ready", timeout=TIMEOUT)
    assert r.status_code == 200, "erp-bridge cannot reach its own database"
    assert r.json()["ready"] is True


# --------------------------------------------------------------------------
# 2. Reconciliation classes
# --------------------------------------------------------------------------

def test_all_three_agreeing_is_clean_and_unlocks_rec():
    out = evaluate(pod(), "100.0", "100.0", "100.0")
    assert out["outcome"] == "CLASSIFIED"
    assert out["class"] == "CLEAN"
    assert out["rec_eligible"] is True


def test_chain_over_meter_is_critical_and_freezes_the_pod():
    """The control the whole integration justifies itself by.

    chain > meter is the only class indicating the two-node trust assumption
    (Aggregator Bridge + Chain Bridge) may have failed.
    """
    out = evaluate(pod(), "100.0", "140.0", "100.0")
    assert out["class"] == "CRITICAL"
    assert out["freeze_pod"] is True
    assert out["freeze_rec_issuance"] is True
    assert out["page_on_call"] is True
    assert out["rec_eligible"] is False


def test_critical_is_raised_without_an_erp_readback():
    """Phase 1 has no ERP feed. The over-mint control must not wait for one."""
    out = evaluate(pod(), "100.0", "140.0")
    assert out["class"] == "CRITICAL"


def test_erp_alone_disagreeing_is_a_utility_side_divergence():
    out = evaluate(pod(), "100.0", "100.0", "80.0")
    assert out["class"] == "ERP_DIVERGENCE"
    assert out["freeze_pod"] is False, "a utility bookkeeping error must not freeze the PoD"
    assert out["rec_eligible"] is False


def test_undermint_with_no_deferral_is_unexplained_and_fails_rec_closed():
    out = evaluate(pod(), "100.0", "80.0", "80.0")
    assert out["class"] == "UNEXPLAINED"
    assert out["freeze_rec_issuance"] is True


def test_a_missing_erp_figure_is_incomplete_never_clean():
    out = evaluate(pod(), "100.0", "100.0")
    assert out["outcome"] == "INCOMPLETE"
    assert "class" not in out or out.get("class") != "CLEAN"


def test_a_verdict_is_persisted_and_readable_back():
    p = pod()
    evaluate(p, "100.0", "140.0", "100.0")
    r = requests.get(f"{BASE}/admin/recon/{p}", timeout=TIMEOUT)
    assert r.status_code == 200
    stored = r.json()
    assert stored["break_class"] == "CRITICAL"
    assert stored["rec_eligible"] is False


def test_an_incomplete_verdict_persists_as_incomplete():
    p = pod()
    evaluate(p, "100.0", "100.0")
    stored = requests.get(f"{BASE}/admin/recon/{p}", timeout=TIMEOUT).json()
    assert stored["break_class"] == "INCOMPLETE"
    assert stored["rec_eligible"] is False


def test_a_critical_break_appears_in_the_open_breaks_view():
    p = pod()
    evaluate(p, "100.0", "140.0", "100.0")
    rows = requests.get(f"{BASE}/admin/breaks", timeout=TIMEOUT).json()
    assert any(r["pod"] == p and r["break_class"] == "CRITICAL" for r in rows)


# --------------------------------------------------------------------------
# 3. TD-002 deferral ledger and catch-up
#
# Until the catch-up service was wired, nothing wrote to erp_td002_pending —
# so the deferral sum the reconciler reads was permanently zero and
# KNOWN_DEFERRED could never fire. Every late-telemetry PoD would have been
# reported UNEXPLAINED, freezing its REC issuance for being slow rather than
# wrong. These cases exist so that cannot silently return.
# --------------------------------------------------------------------------

WINDOW = 900_000


def record_deferral(pod_id, window_start, deferred_kwh):
    r = requests.post(
        f"{BASE}/admin/td002/{pod_id}",
        json={"window_start_ms": window_start, "deferred_kwh": deferred_kwh},
        timeout=TIMEOUT,
    )
    assert r.status_code == 201, f"{r.status_code}: {r.text}"


def test_a_recorded_deferral_is_listed():
    p = pod()
    record_deferral(p, PERIOD_START, "6.0")
    rows = requests.get(f"{BASE}/admin/td002/{p}", timeout=TIMEOUT).json()
    assert len(rows) == 1
    assert rows[0]["window_start_ms"] == PERIOD_START
    assert rows[0]["cycles_aged"] == 0


def test_a_shortfall_matching_a_deferral_is_known_deferred_not_unexplained():
    """The class the ledger exists to make reachable."""
    p = pod()
    record_deferral(p, PERIOD_START, "6.0")
    out = evaluate(p, "100.0", "94.0", "94.0")
    assert out["class"] == "KNOWN_DEFERRED", out
    assert out["alert"] is False, "a fresh deferral must not page anyone"
    assert out["freeze_pod"] is False
    assert out["rec_eligible"] is False


def test_the_same_shortfall_without_a_deferral_is_unexplained():
    """Contrast case: the ledger is what separates 'late' from 'wrong'."""
    out = evaluate(pod(), "100.0", "94.0", "94.0")
    assert out["class"] == "UNEXPLAINED"
    assert out["freeze_rec_issuance"] is True


def test_a_deferral_larger_than_the_shortfall_does_not_excuse_it():
    p = pod()
    record_deferral(p, PERIOD_START, "2.0")
    out = evaluate(p, "100.0", "80.0", "80.0")
    assert out["class"] == "UNEXPLAINED"


def test_settling_with_no_deferral_recorded_is_not_an_error():
    r = requests.post(
        f"{BASE}/admin/td002/{pod()}/settle",
        json={"window_start_ms": PERIOD_START, "settled_cumulative_kwh": "100.0"},
        timeout=TIMEOUT,
    )
    assert r.status_code == 200
    assert r.json()["action"] == "NOTHING_DEFERRED"


def test_settling_a_deferral_with_no_exported_document_is_refused():
    """A catch-up needs something to correct."""
    p = pod()
    record_deferral(p, PERIOD_START, "2.0")
    r = requests.post(
        f"{BASE}/admin/td002/{p}/settle",
        json={"window_start_ms": PERIOD_START, "settled_cumulative_kwh": "100.0"},
        timeout=TIMEOUT,
    )
    assert r.status_code == 422, r.text
    assert "never exported" in r.text


def test_a_backwards_register_is_refused_rather_than_posted():
    """A cumulative register that went down is a data-integrity event.

    Posting it would launder tampering evidence into the ERP.
    """
    p = pod()
    record_deferral(p, PERIOD_START, "2.0")
    r = requests.post(
        f"{BASE}/admin/td002/{p}/settle",
        json={
            "window_start_ms": PERIOD_START,
            "settled_cumulative_kwh": "-1.0",
            "period_state": "OPEN",
        },
        timeout=TIMEOUT,
    )
    assert r.status_code == 422


def test_a_negative_deferral_is_refused():
    r = requests.post(
        f"{BASE}/admin/td002/{pod()}",
        json={"window_start_ms": PERIOD_START, "deferred_kwh": "-5.0"},
        timeout=TIMEOUT,
    )
    assert r.status_code == 400


def test_an_unaligned_window_is_refused():
    r = requests.post(
        f"{BASE}/admin/td002/{pod()}",
        json={"window_start_ms": PERIOD_START + 7, "deferred_kwh": "1.0"},
        timeout=TIMEOUT,
    )
    assert r.status_code == 400


def test_an_unknown_period_state_is_refused():
    p = pod()
    record_deferral(p, PERIOD_START, "1.0")
    r = requests.post(
        f"{BASE}/admin/td002/{p}/settle",
        json={
            "window_start_ms": PERIOD_START,
            "settled_cumulative_kwh": "100.0",
            "period_state": "SORT-OF-OPEN",
        },
        timeout=TIMEOUT,
    )
    assert r.status_code == 400


def test_ageing_advances_the_cycle_counter_on_open_deferrals():
    """cycles_aged drives the two-cycle alert.

    It is an endpoint rather than a timer because a billing cycle is a period
    close, not a wall-clock interval. Nothing called it until 2026-07-30, so the
    counter stayed 0 and the alert could never fire.
    """
    p = pod()
    record_deferral(p, PERIOD_START, "3.0")
    assert requests.get(f"{BASE}/admin/td002/{p}", timeout=TIMEOUT).json()[0]["cycles_aged"] == 0

    r = requests.post(f"{BASE}/admin/td002/age", timeout=TIMEOUT)
    assert r.status_code == 200, r.text
    assert r.json()["aged"] >= 1

    assert requests.get(f"{BASE}/admin/td002/{p}", timeout=TIMEOUT).json()[0]["cycles_aged"] >= 1


def test_a_deferral_aged_past_two_cycles_alerts():
    p = pod()
    record_deferral(p, PERIOD_START, "6.0")
    for _ in range(3):
        requests.post(f"{BASE}/admin/td002/age", timeout=TIMEOUT)
    out = evaluate(p, "100.0", "94.0", "94.0")
    assert out["class"] == "KNOWN_DEFERRED"
    assert out["alert"] is True, "past two cycles a deferral stops being routine"


# --------------------------------------------------------------------------
# 4. Outbox + input validation
# --------------------------------------------------------------------------

def test_outbox_summary_is_queryable():
    r = requests.get(f"{BASE}/admin/outbox/summary", timeout=TIMEOUT)
    assert r.status_code == 200
    for state, count in r.json().items():
        assert state in (
            "PENDING", "IN_FLIGHT", "CONFIRMED", "FAILED", "SUPERSEDED"
        ), f"unknown outbox state {state}"
        assert isinstance(count, int)


def test_an_unknown_outbox_key_is_a_404_not_a_500():
    r = requests.get(
        f"{BASE}/admin/outbox/erp:PoD-nonexistent:0:meter_reading", timeout=TIMEOUT
    )
    assert r.status_code == 404


def test_a_key_without_the_erp_prefix_is_rejected():
    r = requests.get(f"{BASE}/admin/outbox/not-an-erp-key", timeout=TIMEOUT)
    assert r.status_code == 400


def test_a_non_decimal_quantity_is_rejected():
    r = requests.post(
        f"{BASE}/admin/recon/{pod()}/evaluate",
        json={
            "period_start_ms": PERIOD_START,
            "period_end_ms": PERIOD_END,
            "meter_kwh": "not-a-number",
            "chain_kwh": "100.0",
        },
        timeout=TIMEOUT,
    )
    assert r.status_code == 400


def test_a_pod_containing_the_key_delimiter_is_rejected():
    """':' would let two distinct PoDs collide on one outbox primary key."""
    r = requests.post(
        f"{BASE}/admin/recon/PoD%3Awith%3Acolons/evaluate",
        json={
            "period_start_ms": PERIOD_START,
            "period_end_ms": PERIOD_END,
            "meter_kwh": "1.0",
            "chain_kwh": "1.0",
        },
        timeout=TIMEOUT,
    )
    assert r.status_code == 400
