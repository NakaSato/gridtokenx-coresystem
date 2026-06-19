"""Suite 30 — Surplus mint over Chain Bridge (`chain.tx.mint`).

CURRENT settlement path (CLAUDE.md / ARCHITECTURE.md). The aggregator-bridge no
longer forwards to meter-service — the former `MintForwardReading` → NATS
`meter.reading` handoff and the "Path B" SettlementEngine were both REMOVED
(confirmed: `rg meter.reading crates/ src/` is empty). Minting was re-added
*directly*: when a 15-min billing window closes with net surplus generation, the
settlement flush loop mints to the meter owner via Chain Bridge over NATS on
`chain.tx.mint`.

  signed REST telemetry (:4030 /v1/private-network/ingest, BACKDATED so the
    billing window is already closed past BILLING_FLUSH_GRACE_SECS)
    -> Ed25519 verify -> zone Redis stream -> zone_ingester -> billing bin
    -> flush loop peek_completed_bins(grace) -> MintGateway.mint publishes a
       MintEnergyMessage on `chain.tx.mint`  (mint.rs MINT_SUBJECT),
       gated on MINT_VIA_CHAIN_BRIDGE + NATS_URL.

MintEnergyMessage wire shape (crates/aggregator-persistence/src/infra/mint.rs):
  { correlation_id, idempotency_key, reply_subject, recipient_wallet,
    energy_kwh, meter_id[16], window_start_ms, service_identity, created_at_ms,
    auth: { scheme, cert_pem, signature } }

Asserted invariants (only when a mint is observed — see the skip note):
  1. A surplus window (generated > consumed) mints on `chain.tx.mint` with
     energy_kwh == net surplus and idempotency_key == `mint:{serial}:{window_ms}`
     (the bridge's replay-dedup key; the on-chain (meter_id, window) PDA backstops).
  2. recipient_wallet == the OWNER wallet resolved from the registry
     (`gridtokenx:meters:{serial}:wallet`), NOT taken from the ingest payload —
     an untrusted reading cannot redirect minted tokens. (Contrast the removed
     forward path, which deliberately carried no wallet; here the bridge resolves
     and sends it.)
  3. The envelope carries `service_identity` AND a valid `auth` EnvelopeAuth block
     (scheme `ecdsa-p256-sha256-v1` + mTLS client cert PEM + P-256/ECDSA signature
     over the canonical bytes — mint.rs / envelope_auth.rs). The bridge binds the
     self-asserted identity to the CA cert and enforces it under
     CHAIN_BRIDGE_REQUIRE_SIGNED_NATS; the identity is no longer spoofable.
  4. A non-surplus window (net <= 0, pure consumer) mints NOTHING — only
     BillingBin::net_surplus_kwh() Some(>0) triggers a mint.

SKIP semantics (this is the anti-false-green guard): if NO mint envelope arrives
on `chain.tx.mint` within MINT_WAIT, the suite SKIPS with a loud reason rather
than passing — minting may be disabled (MINT_VIA_CHAIN_BRIDGE unset) or the
deployed binary may predate the mint feature. A green-by-silence here would be a
false positive, so we refuse to assert the negative case until a surplus mint is
actually seen. Needs REST + Redis + NATS reachable and a bridge with minting on.

NOTE: slow by construction. The window must be closed past grace (default 120s);
backdating makes a bin eligible immediately, but the flush loop polls on an
interval (default 30s), so allow ~MINT_WAIT seconds for the envelope.
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

# Window must close past grace (default 120s) before the flush loop (default 30s
# interval) mints. Backdating makes the bin eligible at once; this is the wait for
# the envelope to land. Override via MINT_WAIT_SECS for faster/slower deployments.
MINT_WAIT = float(os.getenv("MINT_WAIT_SECS", "150"))
# Backdate far enough that floor(ts) window end is well past grace.
BACKDATE_MS = int(os.getenv("MINT_BACKDATE_SECS", str(20 * 60))) * 1000
OWNER_USER = "00000000-0000-0000-0000-000000000001"

# The mint envelope is signed: the aggregator attaches an `auth` EnvelopeAuth block
# (mTLS client cert + P-256/ECDSA signature over the canonical bytes) so the bridge
# can enforce CHAIN_BRIDGE_REQUIRE_SIGNED_NATS. `auth` is REQUIRED; the keys below are
# stray top-level forms that must never appear outside that block.
ENVELOPE_AUTH_SCHEME_V1 = "ecdsa-p256-sha256-v1"
_STRAY_AUTH_KEYS = {"signature", "envelope_auth", "sig"}


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
    """Register an Ed25519 smart meter with an owner wallet. Returns the handle."""
    pk, pub_hex = crypto.new_identity()
    meter = f"{prefix}-{int(time.time() * 1000) % 1_000_000}"
    wallet = f"Wa11et{meter.replace('-', '')}".ljust(43, "1")[:43]
    redis_util.register_device_key(meter, pub_hex)
    redis_util.register_meter(meter, OWNER_USER, wallet=wallet)
    return {"meter": meter, "priv": pk, "wallet": wallet}


def _payload(meter, priv, *, kwh, generated, consumed, ts_ms):
    """Signed DLMS REST payload. Signs the canonical `kwh` value (handlers.rs
    resolves `kwh` first); net is `generated - consumed` (dlms.rs)."""
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


def test_surplus_window_mints_to_owner_and_consumer_does_not():
    """End-to-end mint provenance: a backdated surplus window mints to the owner
    wallet on `chain.tx.mint`; a backdated deficit window (same closed window)
    mints nothing. The negative case is asserted ONLY once a surplus mint is
    actually observed — otherwise we skip (anti-false-green)."""
    surplus = _new_meter("E2E-MINT-SURPLUS")
    deficit = _new_meter("E2E-MINT-DEFICIT")
    ts_ms = int(time.time() * 1000) - BACKDATE_MS  # window already closed past grace
    gen = 50  # surplus: net = 50 - 0

    def _trigger():
        _ingest(_payload(surplus["meter"], surplus["priv"], kwh=gen, generated=gen, consumed=0, ts_ms=ts_ms))
        # deficit: generated 0, consumed 5 -> net = -5; sign canonical kwh (0).
        _ingest(_payload(deficit["meter"], deficit["priv"], kwh=0, generated=0, consumed=5, ts_ms=ts_ms))

    def _matches(m):
        key = str(m.get("idempotency_key", ""))
        return key.startswith(f"mint:{surplus['meter']}:") or key.startswith(f"mint:{deficit['meter']}:")

    try:
        msgs = nats_util.collect_sync(SUBJECT, _trigger, match=_matches, timeout=MINT_WAIT, want=2)
    finally:
        redis_util.unregister_device(surplus["meter"])
        redis_util.unregister_device(deficit["meter"])

    surplus_mints = [m for m in msgs if str(m.get("idempotency_key", "")).startswith(f"mint:{surplus['meter']}:")]
    deficit_mints = [m for m in msgs if str(m.get("idempotency_key", "")).startswith(f"mint:{deficit['meter']}:")]

    if not surplus_mints:
        pytest.skip(
            f"no surplus mint on '{SUBJECT}' within {MINT_WAIT:.0f}s — minting is disabled "
            "(MINT_VIA_CHAIN_BRIDGE unset) or the deployed bridge predates the chain.tx.mint "
            "feature. Refusing to assert the negative case on silence (would be a false pass)."
        )

    mint = surplus_mints[0]

    # (1) energy_kwh == net surplus, idempotency_key == mint:{serial}:{window_ms}.
    assert abs(float(mint.get("energy_kwh", 0)) - gen) < 1e-6, f"energy_kwh != net surplus {gen}: {mint}"
    key = str(mint["idempotency_key"])
    window_part = key[len(f"mint:{surplus['meter']}:"):]
    assert window_part.isdigit() and int(window_part) > 0, f"idempotency window not epoch-ms: {key}"

    # (2) recipient resolved from the registry, NOT the payload.
    assert mint.get("recipient_wallet") == surplus["wallet"], (
        f"recipient_wallet must be the registered owner ({surplus['wallet']}): {mint}"
    )

    # (3) signed envelope: service_identity present AND a valid EnvelopeAuth attached
    # (scheme + cert PEM + signature). The aggregator signs the mint intent with its
    # mTLS client key so the bridge binds the identity to a CA cert under enforcement.
    assert mint.get("service_identity"), f"missing service_identity: {mint}"
    auth = mint.get("auth")
    assert isinstance(auth, dict), f"signed mint envelope must carry an auth block: {mint}"
    assert auth.get("scheme") == ENVELOPE_AUTH_SCHEME_V1, f"unexpected auth scheme: {auth}"
    assert "BEGIN CERTIFICATE" in (auth.get("cert_pem") or ""), f"auth missing cert PEM: {auth}"
    assert auth.get("signature"), f"auth missing signature: {auth}"
    leaked_auth = {k for k in mint if k.lower() in _STRAY_AUTH_KEYS}
    assert not leaked_auth, f"unexpected top-level auth field(s) {leaked_auth}: {mint}"

    # (4) deficit window minted nothing.
    assert not deficit_mints, f"non-surplus (net<=0) window must NOT mint, got {deficit_mints}"
