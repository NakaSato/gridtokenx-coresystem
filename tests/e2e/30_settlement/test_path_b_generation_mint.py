"""Path B generation mint — telemetry -> billing bin -> Chain Bridge GRID mint.

Exercises the CURRENT in-repo mint flow (trading-service's external generation-mint
REST API was removed in trading `63f59d2`, Phase 5a): the aggregator-bridge now owns
issuance. Flow under test:

  signed REST telemetry (:4030 /v1/private-network/ingest)
    -> Ed25519 verify -> zone Redis stream -> zone ingester
    -> 15-min BillingBin keyed by (meter, window), user_id from
       gridtokenx:meters:{serial}:user_id (Redis)
    -> SettlementEngine tick (60s) peeks completed bins
    -> IAM gRPC GetUserWallet(user_id) resolves the linked primary wallet
    -> blockchain-core execute_generation_mint_batch: ATA-idempotent-create +
       mint_to_wallet (Token-2022), UNSIGNED, submitted via NATS JetStream
    -> Chain Bridge signs (Vault / insecure keypair) + sends
    -> assert EXACT on-chain delta == kwh * 1e9 on the user's GRID ATA.

Bins complete when their window's end_time passes — readings are backdated into an
already-closed 15-min window so the next engine tick settles them immediately.

OPT-IN: the aggregator must be launched with the mint path enabled, which the
default app.sh bring-up does not do. Relaunch it with:

  MINT_VIA_CHAIN_BRIDGE=true NATS_URL=nats://localhost:9020 \
  CHAIN_BRIDGE_URL=http://localhost:5040 CHAIN_BRIDGE_INSECURE=true \
  IAM_SERVICE_URL=http://127.0.0.1:5010 \
  SOLANA_PAYER_KEY=EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ \
  SOLANA_ENERGY_TOKEN_PROGRAM_ID=<from .env> \
  ... usual IOT_GATEWAY_PORT=4030 GRPC_PORT=5030 REDIS_URL KAFKA env ...

then run with E2E_MINT_VIA_CHAIN_BRIDGE=1. Without the opt-in env this skips.
"""
import datetime
import os
import time

import pytest
import requests

import chain
import crypto
import redis_util

ORACLE_REST = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
INGEST_URL = f"{ORACLE_REST}/v1/private-network/ingest"
IAM_URL = os.getenv("IAM_URL", "http://localhost:4010")

GRID_DECIMALS_SCALE = 1_000_000_000  # GRID has 9 decimals (settlement_engine.rs:221)
# 60s engine tick + NATS submit + confirmation; generous.
SETTLE_TIMEOUT = float(os.getenv("E2E_SETTLE_TIMEOUT", "180"))


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
        reason="opt-in: relaunch aggregator-bridge with MINT_VIA_CHAIN_BRIDGE=true "
               "(+ NATS_URL, IAM_SERVICE_URL=:5010 gRPC, CHAIN_BRIDGE_URL) and set "
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
    """A timestamp safely inside an already-closed 15-min window.

    Aligns to the window grid (aggregator.rs get_window_start) and picks the
    window two slots back, +60s in, so all readings stamped from it share one
    bin whose end_time is comfortably in the past.
    """
    now = int(time.time())
    window = 15 * 60
    current_start = now - (now % window)
    return (current_start - 2 * window + 60) * 1000


def _rest_payload(meter_id: str, generated_kwh: float, ts_ms: int, signature: str):
    dt = datetime.datetime.fromtimestamp(ts_ms / 1000, tz=datetime.timezone.utc)
    iso = dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    # Only energy_generated: the REST canonical sign-value precedence is
    # kwh -> energy_consumed -> energy_generated (handlers.rs canonical_sign_value),
    # so with the others absent the device signs the generated value. The zone
    # ingester maps payload.energy_generated -> DeviceMetrics::Energy.generated_kwh
    # (handlers.rs:260) which is what BillingBin accumulates.
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


def test_path_b_generation_mint_credits_exact_grid(new_user):
    grid_mint = _resolve_grid_mint()
    if not grid_mint:
        pytest.skip("GRID mint pubkey unresolvable (set ENERGY_TOKEN_MINT or "
                    "ENERGY_TOKEN_PROGRAM_ID)")
    if not chain.reachable():
        pytest.skip("Chain Bridge unreachable over plain HTTP — start with "
                    "CHAIN_BRIDGE_INSECURE=true")

    owner = new_user["wallet"]
    user_id = new_user["user_id"]
    assert owner and user_id, "new_user must provide linked wallet + user_id"

    # Device with a registered Ed25519 key, mapped to OUR user (not nil) so the
    # settlement engine can resolve the recipient wallet via IAM GetUserWallet.
    priv, pub_hex = crypto.new_identity()
    meter = f"E2E-PATHB-{int(time.time()*1000) % 1000000}"
    redis_util.register_device_key(meter, pub_hex)
    redis_util.register_meter(meter, user_id)

    try:
        before = chain.token_balance_of(owner, grid_mint)

        # Three readings in ONE closed window -> one bin of exactly 50 kWh.
        # Integer-valued floats so the signed canonical value is stable ("20", "10").
        base_ts = _closed_window_ts_ms()
        total_kwh = 0
        for i, kwh in enumerate((20, 20, 10)):
            ts = base_ts + i * 30_000  # 30s apart, same 15-min window
            sig = crypto.sign_telemetry(priv, meter, kwh, ts)
            r = requests.post(INGEST_URL,
                              json=_rest_payload(meter, float(kwh), ts, sig), timeout=10)
            assert r.status_code in (200, 202), \
                f"ingest reading {i} rejected: {r.status_code} {r.text}"
            total_kwh += kwh

        expected_delta = total_kwh * GRID_DECIMALS_SCALE

        # Engine ticks every 60s; the bin is already complete so the next tick
        # resolves the wallet and submits the batch mint via NATS -> Chain Bridge.
        deadline = time.time() + SETTLE_TIMEOUT
        after = before
        while time.time() < deadline:
            try:
                after = chain.token_balance_of(owner, grid_mint)
            except Exception:
                after = before  # transient read failure — keep polling
            if after > before:
                break
            time.sleep(5)

        assert after > before, (
            f"no GRID minted within {SETTLE_TIMEOUT}s (before={before}, after={after}) — "
            "check the aggregator was relaunched with MINT_VIA_CHAIN_BRIDGE=true and its "
            "log shows '⚡ Generation mint path: Chain Bridge (Vault-signed)'"
        )
        assert after - before == expected_delta, (
            f"mint delta mismatch: expected {expected_delta} atomic "
            f"({total_kwh} kWh * 1e9), got {after - before}"
        )
    finally:
        redis_util.unregister_device(meter)
