"""Suite 30 — Generation settlement & minting (Oracle -> Platform -> Chain Bridge -> on-chain).

FLOW (ref docs/MINTING_E2E_FLOW.md):
  signed generation reading -> Oracle ingest -> Redis zone stream -> zone_ingester
  -> Aggregator (15-min bins) -> SettlementEngine (60s tick, flushes COMPLETED bins)
  -> POST {API_SERVICES_URL}/api/v1/settlement/generation-mint  [platform, separate repo]
  -> publishes NATS chain.tx.submit -> Chain Bridge signs+lands -> GRID minted to wallet.

CROSS-SERVICE: the generation-mint settlement + its storage live in gridtokenx-api
(API_SERVICES_URL :4000), which is NOT a submodule of this superproject. So the
deterministic in-repo signals are service LOGS + on-chain balance via Chain Bridge.
This suite requires the FULL stack and skips loudly if any hop is absent.

WINDOW TRICK: aggregation window is a hardcoded 15 min, bucketed by reading timestamp
(aggregator.rs WINDOW_MINUTES=15). We BACKDATE readings into a past window so the bin
is already past its end-time and the next 60s settlement tick flushes it — no 15-min wait.

Run: cd tests/e2e && python -m pytest 30_settlement -v
"""
import os
import time

import pytest
import requests

import chain
import crypto
import dlogs
import redis_util

ORACLE_REST = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
API_SERVICES_URL = os.getenv("API_SERVICES_URL", "http://localhost:4000")
INGEST_URL = f"{ORACLE_REST}/v1/private-network/ingest"
# api_key_auth gates ingest (auth.rs); aggregator seeds `e2e-test-key` in its static
# GRIDTOKENX_API_KEYS for the harness (docker-compose.yml:755). Missing → 401 at auth.
INGEST_HEADERS = {"X-API-KEY": os.getenv("AGGREGATOR_API_KEY", "e2e-test-key")}

AGGREGATOR_CONTAINER = os.getenv("AGGREGATOR_CONTAINER", "gridtokenx-aggregator-bridge")
CHAIN_CONTAINER = os.getenv("CHAIN_CONTAINER", "gridtokenx-chain-bridge")

# GRID (energy-token) mint that generation settlement credits. Bootstrap-generated,
# not statically known in this repo (infra/solana/currency-mint.json was removed and
# .env ENERGY_TOKEN_MINT is empty), so the on-chain balance check resolves it from
# env and skips when unknown.
GRID_MINT = (os.getenv("ENERGY_TOKEN_MINT") or os.getenv("GRID_MINT")
             or os.getenv("CURRENCY_MINT") or "").strip()

# Settlement tick is 60s; backdated bin flushes on the next tick. Allow margin.
SETTLE_TIMEOUT = float(os.getenv("E2E_SETTLE_TIMEOUT", "150"))


def _oracle_up():
    try:
        requests.get(f"{ORACLE_REST}/health", timeout=3)
        return True
    except Exception:
        return False


def _platform_up():
    try:
        requests.get(f"{API_SERVICES_URL}/health", timeout=3)
        return True
    except Exception:
        return False


def _redis_up():
    try:
        redis_util.client().ping()
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(
    not (_oracle_up() and _redis_up()),
    reason="Oracle Bridge or Redis unreachable — full stack required for settlement e2e",
)


def _send_generation_reading(meter_id, priv, generated_kwh, ts_ms):
    """Backdated GENERATION reading. Mint settlement is driven by energy_generated."""
    sig = crypto.sign_telemetry(priv, meter_id, str(generated_kwh), ts_ms)
    import datetime
    dt = datetime.datetime.fromtimestamp(ts_ms / 1000, tz=datetime.timezone.utc)
    iso = dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    payload = {
        "protocol": "dlms",
        "device_id": meter_id,
        "payload": {
            "device_id": meter_id,
            "timestamp": iso,
            "energy_generated": float(generated_kwh),
            "energy_consumed": 0.0,
            "signature": sig,
        },
    }
    return requests.post(INGEST_URL, json=payload, headers=INGEST_HEADERS, timeout=5)


@pytest.fixture
def gen_device(new_user):
    """Registered device whose meter maps to the real IAM user_id (mint target).

    Mapping to the actual user (not a nil uuid) lets the settlement resolver credit
    that user's custodial wallet (`new_user["wallet"]`), which the on-chain balance
    check then reads via Chain Bridge.
    """
    pk, pub_hex = crypto.new_identity()
    meter_id = f"E2E-GEN-{int(time.time()*1000)%1000000}"
    redis_util.register_device_key(meter_id, pub_hex)
    owner_uuid = new_user.get("user_id") or "00000000-0000-0000-0000-000000000001"
    redis_util.register_meter(meter_id, owner_uuid)
    yield {"meter_id": meter_id, "priv": pk, "user": new_user}
    redis_util.unregister_device(meter_id)


def test_backdated_generation_triggers_settlement(gen_device):
    """Backdated generation readings flush a completed bin and drive a mint settlement.

    Asserts via service logs (platform settlement storage is out-of-repo). Requires
    the full stack incl. API_SERVICES_URL platform + Chain Bridge.
    """
    if not _platform_up():
        pytest.skip(f"platform/api-services not up at {API_SERVICES_URL} (separate repo) — "
                    "generation-mint endpoint unavailable")
    if not dlogs.container_running(AGGREGATOR_CONTAINER):
        pytest.skip(f"{AGGREGATOR_CONTAINER} not a running docker container — cannot scrape logs")

    meter, priv = gen_device["meter_id"], gen_device["priv"]
    # Timestamp ~25 min in the past => its 15-min window already ended.
    base = int((time.time() - 25 * 60) * 1000)
    for i in range(3):
        r = _send_generation_reading(meter, priv, 10.0, base + i * 1000)
        assert r.status_code in (200, 202), f"reading {i} rejected: {r.status_code} {r.text}"

    # SettlementEngine logs when it flushes completed bins.
    flushed = dlogs.wait_for_log(AGGREGATOR_CONTAINER, "completed billing bins",
                                 timeout=SETTLE_TIMEOUT)
    assert flushed, ("no 'completed billing bins' log within timeout — bin not flushed "
                     "(check zone_ingester is consuming Redis streams + settlement tick)")


def test_mint_tx_reaches_chain_bridge(gen_device):
    """After settlement, a chain.tx.submit lands at Chain Bridge (success log)."""
    if not _platform_up():
        pytest.skip("platform/api-services not up — no mint submission")
    if not dlogs.container_running(CHAIN_CONTAINER):
        pytest.skip(f"{CHAIN_CONTAINER} not running — cannot scrape chain bridge logs")

    meter, priv = gen_device["meter_id"], gen_device["priv"]
    base = int((time.time() - 25 * 60) * 1000)
    for i in range(3):
        _send_generation_reading(meter, priv, 10.0, base + i * 1000)

    # Chain Bridge logs success on tx submission/landing.
    landed = dlogs.wait_for_log(CHAIN_CONTAINER, "Success", timeout=SETTLE_TIMEOUT) \
        or dlogs.wait_for_log(CHAIN_CONTAINER, "chain.tx.submit", timeout=5)
    assert landed, "no Chain Bridge tx success/submit log after settlement"


def test_onchain_balance_increase(gen_device):
    """Definitive check: the prosumer's on-chain GRID balance increases after a
    backdated generation settlement, read via Chain Bridge GetTokenAccountBalance.

    This is the end-to-end proof that telemetry -> settlement -> mint actually
    credited tokens on-chain (the log-based tests above only prove the pipeline
    fired). It needs the FULL stack, so it skips loudly when any piece is absent:
      - platform :4000 (out-of-repo) drives the mint;
      - the GRID mint pubkey must be resolvable (ENERGY_TOKEN_MINT/GRID_MINT env);
      - the user's custodial wallet must be known (IAM register/verify);
      - Chain Bridge must answer reads over plain HTTP (CHAIN_BRIDGE_INSECURE=true).
    """
    if not _platform_up():
        pytest.skip(f"platform/api-services not up at {API_SERVICES_URL} — no mint driver")
    if not GRID_MINT:
        pytest.skip("GRID mint pubkey unknown (set ENERGY_TOKEN_MINT/GRID_MINT) — "
                    "bootstrap-generated, not statically known in this repo")
    owner = gen_device["user"].get("wallet")
    if not owner:
        pytest.skip("IAM did not return a custodial wallet_address for the user")
    if not chain.reachable():
        pytest.skip("Chain Bridge unreachable over plain HTTP (mTLS-only or down) — "
                    "start with CHAIN_BRIDGE_INSECURE=true")

    token_account = chain.ata(owner, GRID_MINT)
    before = chain.token_balance_of(owner, GRID_MINT)

    meter, priv = gen_device["meter_id"], gen_device["priv"]
    # Backdated ~25 min => its 15-min window already closed; flushes on next tick.
    base = int((time.time() - 25 * 60) * 1000)
    minted_kwh = 10.0
    n = 3
    for i in range(n):
        r = _send_generation_reading(meter, priv, minted_kwh, base + i * 1000)
        assert r.status_code in (200, 202), f"reading {i} rejected: {r.status_code} {r.text}"

    # Mint is async (settlement tick -> NATS -> Chain Bridge -> land). Poll the ATA.
    deadline = time.time() + SETTLE_TIMEOUT
    after = before
    while time.time() < deadline:
        try:
            after = chain.token_balance_of(owner, GRID_MINT)
            if after > before:
                break
        except chain.ChainBridgeError:
            pass  # ATA may not exist until the first mint creates it — keep polling.
        time.sleep(3)

    assert after > before, (
        f"prosumer GRID balance did not increase after settlement: "
        f"before={before} after={after} ATA={token_account} mint={GRID_MINT} owner={owner}")
