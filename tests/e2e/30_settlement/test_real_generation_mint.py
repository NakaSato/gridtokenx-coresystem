"""Suite 30 — REAL generation-mint flow, driven directly at trading-service.

Unlike test_settlement.py (which drives mint through the out-of-repo platform :4000
and asserts via service logs), this test exercises the genuine settlement -> on-chain
mint path WITHOUT :4000 by POSTing the generation-mint endpoint that lives INSIDE
trading-service — the exact endpoint the oracle SettlementEngine targets via
SETTLEMENT_API_URL (default http://trading-service:8093).

REAL FLOW (verified against source AND a live green run, 2026-06-07):
  POST :8093/api/v1/settlement/generation-mint/batch  {"requests":[{...}]}
    -> trading verifies the Ed25519 signature vs AGGREGATOR_BRIDGE_PUBLIC_KEY
       (rest.rs:914, canonical "{user_id}:{meter_serial}:{kwh}:{start}:{end}")
    -> SettlementService::execute_batched_settlements
    -> BlockchainSettlementProvider::execute_batched_generation_mints builds, per user,
       [create_associated_token_account_idempotent(Token-2022) , mint_to_wallet]
       (energy-token program, SPL Token-2022, mint PDA find_program_address([b"mint_2022"],..))
       and mints kwh * 1_000_000_000 atomic units (9 dec) to the prosumer's Token-2022 ATA.
    -> the whole tx is submitted THROUGH Chain Bridge (gRPC submit_transaction ->
       pre-sign simulate -> Vault/Insecure sign -> send). Chain Bridge IS the write path.

CORRECTED FINDING (an earlier draft of this file wrongly claimed the mint bypassed
Chain Bridge via direct Solana RPC — that is FALSE). The mint write path goes through
Chain Bridge's gRPC submit_transaction, matching CLAUDE.md + docs/MINTING_E2E_FLOW.md.
The confusion came from the trading-side `AUTHORITY_WALLET_PATH` keypair, which is only
the fee-payer/authority signer on the instruction; the Solana RPC submission itself is
Chain Bridge's.

Getting this to a live green run required fixing four genuine, previously-unexercised
bugs on the mint path (all committed alongside this test):
  1. anchor bootstrap.ts created the `mint_2022` energy mint with the CLASSIC SPL Token
     program while every client path (and this test) treats it as Token-2022 -> fixed
     bootstrap to canonical Token-2022 (also fixed a malformed Token-2022 id literal).
  2. trading-api startup.rs used axum-0.7 `:param` route syntax -> panicked the REST
     server on axum 0.8 (`{param}` required); REST never bound on :8093.
  3. trading-infra never created the recipient's GRID ATA before minting; MintToWallet
     requires an existing destination -> first-time prosumers failed Anchor 3012
     (AccountNotInitialized). Fixed: prepend idempotent Token-2022 create-ATA.
  4. blockchain-core build_mint_to_wallet_instruction omitted the program's
     `Option<Signer> rec_validator` account slot, shifting every later account by one ->
     payer landed in a non-signer slot -> Anchor 3010 (AccountNotSigner). Fixed: insert
     the `rec_validator = None` (program-id placeholder) account in on-chain order.

NOTE: the REST batch/single endpoints mint directly and do NOT persist a `settlements`
table row — that row is only written by the async OracleConsumer/SettlementWorker path
(settlement.rs insert_settlement), which is out of scope here (separate oracle-stream
/Event-shape mismatch gap). So the observable, persisted hops for THIS drive path are:
signed request accepted (sig verified) -> mint tx returned -> on-chain GRID balance
credited by the EXACT kwh-derived amount. That on-chain exact-amount check is the
strongest proof of all.

BRING-UP (test skips loudly if any is missing — never hard-fails on env gaps):
  - trading-service up at TRADING_URL (:8093) with:
      AUTHORITY_WALLET_PATH=<dev-wallet.json>     (mint authority EzudwoHv…)
      AGGREGATOR_BRIDGE_PUBLIC_KEY=<pubkey of the signing key below>
  - the test must hold the matching aggregator-bridge signing key, via env
      AGGREGATOR_BRIDGE_SIGNING_KEY (or E2E_AGGREGATOR_BRIDGE_SIGNING_KEY):
      a solana keypair json path, OR a base58 32-byte seed / 64-byte secret.
  - GRID mint resolvable: ENERGY_TOKEN_MINT/GRID_MINT, else derived from the
    energy-token program id (ENERGY_TOKEN_PROGRAM_ID / anchor keypair).
  - Chain Bridge reachable over plain HTTP (CHAIN_BRIDGE_INSECURE=true) for the read.
  - prosumer custodial wallet (IAM register/verify via new_user).
  - Solana validator up.

Run: cd tests/e2e && python -m pytest 30_settlement/test_real_generation_mint.py -v
"""
import json
import os
import time
from decimal import Decimal
from pathlib import Path

import pytest
import requests
from cryptography.hazmat.primitives.asymmetric import ed25519

import chain
import crypto

TRADING_URL = os.getenv("TRADING_URL", "http://localhost:8093")
BATCH_URL = f"{TRADING_URL}/api/v1/settlement/generation-mint/batch"

# 9-decimal scaling: trading mints kwh * 1_000_000_000 atomic units
# (BlockchainSettlementProvider::execute_generation_mint settlement.rs:378-380).
GRID_DECIMALS_SCALE = 1_000_000_000

SETTLE_TIMEOUT = float(os.getenv("E2E_SETTLE_TIMEOUT", "150"))
ROOT = Path(__file__).resolve().parents[3]  # repo root (tests/e2e/30_settlement/.. -> repo)
IAM_URL = os.getenv("IAM_URL", "http://localhost:4010")


def _up(url: str) -> bool:
    try:
        requests.get(url, timeout=3)
        return True
    except Exception:
        return False


# Gate at module level so the new_user fixture (which registers via IAM) doesn't ERROR
# when the stack is absent — skip loudly instead. Finer preconditions (signing key,
# GRID mint, Chain Bridge) are checked inside the test.
pytestmark = pytest.mark.skipif(
    not (_up(f"{IAM_URL}/health") and _up(f"{TRADING_URL}/health")),
    reason="IAM or trading-service unreachable — full stack required for real-flow mint",
)


def _resolve_grid_mint() -> str:
    """GRID mint pubkey: explicit env, else derive the mint PDA from the
    energy-token program id (env or the anchor program keypair)."""
    direct = (os.getenv("ENERGY_TOKEN_MINT") or os.getenv("GRID_MINT") or "").strip()
    if direct:
        return direct
    prog = (os.getenv("ENERGY_TOKEN_PROGRAM_ID")
            or os.getenv("SOLANA_ENERGY_TOKEN_PROGRAM_ID") or "").strip()
    if not prog:
        kp = ROOT / "gridtokenx-anchor" / "target" / "deploy" / "energy_token-keypair.json"
        if kp.exists():
            try:
                from solders.keypair import Keypair
                prog = str(Keypair.from_bytes(bytes(json.loads(kp.read_text()))).pubkey())
            except Exception:
                prog = ""
    if prog:
        try:
            return chain.grid_mint_pda(prog)
        except Exception:
            return ""
    return ""


def _load_signing_key():
    """Load the aggregator-bridge Ed25519 signing key the test impersonates.

    Accepts a solana keypair json file path (64-int array), or a raw base58
    32-byte seed / 64-byte secret in the env value itself. Returns the
    Ed25519PrivateKey or None if unset/unparseable."""
    raw = (os.getenv("AGGREGATOR_BRIDGE_SIGNING_KEY")
           or os.getenv("E2E_AGGREGATOR_BRIDGE_SIGNING_KEY") or "").strip()
    if not raw:
        return None
    seed = None
    p = Path(raw)
    if p.exists():
        try:
            arr = json.loads(p.read_text())
            seed = bytes(arr)[:32]
        except Exception:
            return None
    else:
        try:
            import base58
            decoded = base58.b58decode(raw)
            seed = decoded[:32]
        except Exception:
            return None
    try:
        return ed25519.Ed25519PrivateKey.from_private_bytes(seed)
    except Exception:
        return None


def test_real_generation_mint_credits_exact_grid(new_user):
    grid_mint = _resolve_grid_mint()
    if not grid_mint:
        pytest.skip("GRID mint pubkey unresolvable (set ENERGY_TOKEN_MINT/GRID_MINT, or "
                    "ENERGY_TOKEN_PROGRAM_ID, or provide anchor energy_token keypair)")

    signing_key = _load_signing_key()
    if signing_key is None:
        pytest.skip("aggregator-bridge signing key unavailable — set AGGREGATOR_BRIDGE_SIGNING_KEY "
                    "(keypair json path or base58 seed) that trading trusts via "
                    "AGGREGATOR_BRIDGE_PUBLIC_KEY")

    owner = new_user.get("wallet")
    user_id = new_user.get("user_id")
    if not owner or not user_id:
        pytest.skip("IAM did not return custodial wallet_address / user_id")

    if not chain.reachable():
        pytest.skip("Chain Bridge unreachable over plain HTTP (mTLS-only or down) — "
                    "start with CHAIN_BRIDGE_INSECURE=true")

    try:
        requests.get(f"{TRADING_URL}/health", timeout=3)
    except Exception:
        pytest.skip(f"trading-service not up at {TRADING_URL}")

    # --- before: on-chain GRID balance (Token-2022 ATA, 0 if absent) ---
    token_account = chain.ata(owner, grid_mint)  # Token-2022 derivation by default
    before = chain.token_balance_of(owner, grid_mint)

    # --- build + sign the batch request exactly as the oracle would ---
    # Integer kWh => Decimal Display is unambiguous ("50"), matching the signed string
    # and the JSON string field (rust_decimal accepts a string; ints would 422).
    kwh_str = "50"
    expected_delta = int(Decimal(kwh_str) * GRID_DECIMALS_SCALE)
    meter_serial = f"E2E-GENMINT-{int(time.time() * 1000) % 1000000}"
    now = int(time.time())
    start_time, end_time = now - 15 * 60, now
    sig = crypto.sign_generation_mint(signing_key, user_id, meter_serial, kwh_str,
                                      start_time, end_time)
    body = {"requests": [{
        "user_id": user_id,
        "meter_serial": meter_serial,
        "energy_generated_kwh": kwh_str,
        "start_time": start_time,
        "end_time": end_time,
        "signature": sig,
    }]}

    r = requests.post(BATCH_URL, json=body, timeout=30)
    if r.status_code == 401:
        pytest.skip("trading rejected the oracle signature (401) — bring-up mismatch: "
                    "trading's AGGREGATOR_BRIDGE_PUBLIC_KEY must equal pubkey "
                    f"{crypto.keypair_base58_pubkey(signing_key)}")
    assert r.status_code == 200, f"batch gen-mint failed: {r.status_code} {r.text}"
    resp = r.json()
    assert resp.get("success") is True, f"batch not success: {resp}"
    # Hop: mint tx executed -> a non-empty signature is returned.
    tx_sig = resp.get("tx_signature") or ""
    assert tx_sig, f"no tx_signature returned (mint did not land): {resp}"

    # --- after: poll the ATA until balance grows (mint is synchronous but the read
    # cache / ATA creation can lag a beat) ---
    deadline = time.time() + SETTLE_TIMEOUT
    after = before
    while time.time() < deadline:
        try:
            after = chain.token_balance_of(owner, grid_mint)
            if after > before:
                break
        except chain.ChainBridgeError:
            pass  # ATA created by the first mint — keep polling.
        time.sleep(3)

    delta = after - before
    # Hop: on-chain state — EXACT kWh -> GRID amount (9-decimal scaling).
    assert delta == expected_delta, (
        f"on-chain GRID delta mismatch: got {delta}, expected {expected_delta} "
        f"(={kwh_str} kWh * 1e9). before={before} after={after} "
        f"ATA={token_account} mint={grid_mint} owner={owner} tx={tx_sig}")

    # Sanity: the ATA now materialized on-chain (read via Chain Bridge).
    acct = chain.get_account_data(token_account)
    assert acct, f"ATA {token_account} not readable after mint"
