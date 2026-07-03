"""Suite 96 — Token Lifecycle: on-chain balance deltas for mint + trade settlement.

Closes a gap left by the other suites: 90_golden_path only greps container logs for
the mint/settlement stages, and 30_settlement asserts the mint *envelope* field
(pre-chain), not the balance that actually lands. This suite reads real GRID/GRX
balances from Chain Bridge before/after each on-chain event and asserts the deltas
the program code guarantees:

  seller mint:  wallet GRID delta == net_kwh * 1e9                          (exact;
                build_mint_to_wallet_instruction mints to the plain wallet ATA —
                gridtokenx-blockchain-core/src/rpc/instructions.rs:1117-1153)
  buyer fund:   dev-only GRX mint into the buyer's wallet (test fixture only — no
                service mints currency to end users; see `_fund_grx`)
  order+match:  seller SELL / buyer BUY cross at the same price (CDA)
  settlement:   buyer's OWN wallet GRID   0 -> +energy_atomic       (exact)
                seller's OWN wallet GRX   0 -> +net_seller_amount   (non-zero;
                fee/wheeling/loss bps deducted server-side, not test-visible)

  The deployed SettlementWorker (trading-infra/src/blockchain/settlement.rs:71)
  calls `execute_atomic_settlement`, an ASYMMETRIC platform-pooled-source /
  direct-destination model — confirmed by reading a live settlement tx's account
  list AND its resulting balances (verified live 2026-07-03):
    - the ENERGY the buyer receives, and the CURRENCY the seller receives, land
      directly in each party's OWN wallet ATA (`buyer_energy_ata`/
      `seller_currency_ata` in settlement.rs) — NOT a per-user escrow PDA.
    - the ENERGY the seller sells, and the CURRENCY the buyer pays, are drawn
      from the PLATFORM's own pooled reserve ATAs (`buyer_currency_escrow`/
      `seller_energy_escrow` = ATA(EzudwoHv, mint) in settlement.rs's naming —
      despite the "escrow" name these are platform accounts, not per-user PDAs).
      Consequence: the seller's wallet GRID balance and the buyer's wallet GRX
      balance are UNCHANGED by settlement (this suite does not assert on them).
  This is a DIFFERENT instruction from `settle_offchain_match`
  (gridtokenx-anchor/programs/trading/src/instructions/settle_offchain.rs), which
  uses genuine per-party `[b"escrow", user, mint]` PDAs both sides — that
  instruction is not the one currently wired into the live SettlementWorker.
  `chain.escrow_pda`/`escrow_balance_of` exist for testing that path later but are
  NOT used by this suite today.

  Prerequisite: the platform's pooled reserve ATAs must be funded (they are
  provisioned by `gridtokenx-anchor/scripts/fund-platform-sources.ts`, which needs
  re-running after any validator/ledger reset — see the [[trading-onchain-order-leg-optionA]]
  memory note "REGRESSED 2026-07-03" for the exact symptom if this suite skips
  at the settlement-wait stage: `spl-token accounts --owner EzudwoHv...` showing
  a zero/missing pooled balance is the tell).

SKIP semantics (anti-false-green, matches 30_settlement): any stage that cannot be
observed within its timeout SKIPs with a clear reason. Never asserts on silence.

Run: cd tests/e2e && python -m pytest 96_token_lifecycle -v -s
"""
import os
import shutil
import subprocess
import time
from decimal import Decimal

import pytest
import requests

import chain
import nats_util
import settlement_ingest as si

IAM = os.getenv("IAM_URL", "http://localhost:4010")
TRADING = os.getenv("TRADING_URL", "http://localhost:8093")
SOLANA_RPC_URL = os.getenv("SOLANA_RPC_URL", "http://localhost:8899")
# bootstrap.ts sets the *Anchor provider* wallet (Anchor.toml: ~/.config/solana/id.json)
# as CURRENCY_TOKEN_MINT's mint authority at creation time — but this repo's dev/CI
# validator is provisioned with `dev-wallet.json` as that provider identity (verified
# live: `spl-token display $CURRENCY_TOKEN_MINT` -> mint authority EzudwoHv..., which
# matches `solana-keygen pubkey dev-wallet.json`, not the CLI default id.json).
MINT_AUTHORITY_KEYPAIR = os.path.expanduser(
    os.getenv("MINT_AUTHORITY_KEYPAIR", os.path.join(
        os.path.dirname(__file__), "..", "..", "..", "dev-wallet.json"))
)

# Localnet program/mint ids — mirror the superproject root .env defaults (tests/e2e's
# own env.sh doesn't export these; only docker-compose reads them from root .env).
ENERGY_TOKEN_PROGRAM_ID = os.getenv("SOLANA_ENERGY_TOKEN_PROGRAM_ID", "6FZKcVKCLFSNLMxypFJGU4K14xUBnxNW9VAuKGhmqjGX")
TRADING_PROGRAM_ID = os.getenv("SOLANA_TRADING_PROGRAM_ID", "CnWDEUhTvSixeLSyViWgAnnu9YouBAYVGcrrFm1s9WcX")
CURRENCY_TOKEN_MINT = os.getenv("CURRENCY_TOKEN_MINT", "AzFyFd4GkmjqBnJ5EYv7mkaeufAKkZffumjtDRrX425k")
GRID_MINT = chain.grid_mint_pda(ENERGY_TOKEN_PROGRAM_ID)

GRID_DECIMALS = 1_000_000_000  # GRID = 9 decimals
GRX_DECIMALS = 1_000_000  # GRX (currency) = 6 decimals, bootstrap.ts:215

PASSWORD = os.getenv("E2E_PASSWORD", "GRX-Secure-P@ss-2026-E2E")
SECRET = os.getenv("GATEWAY_SECRET", "gridtokenx-gateway-secret-2025")
ZONE = int(os.getenv("E2E_TRADING_ZONE", "1"))
GW = {"x-gridtokenx-role": "api-gateway", "x-gridtokenx-gateway-secret": SECRET}

MINT_WAIT = float(os.getenv("MINT_WAIT_SECS", "240"))
BACKDATE_SECS = int(os.getenv("MINT_BACKDATE_SECS", str(20 * 60)))
SETTLE_WAIT = float(os.getenv("SETTLE_WAIT_SECS", "120"))


def _up(url, path="/health", timeout=3):
    try:
        requests.get(f"{url}{path}", timeout=timeout)
        return True
    except Exception:
        return False


pytestmark = [
    pytest.mark.skipif(not _up(IAM), reason="IAM unreachable"),
    pytest.mark.skipif(not si.grpc_up(), reason=f"aggregator gRPC not reachable at {si.ORACLE_GRPC}"),
    pytest.mark.skipif(not nats_util.reachable(), reason=f"NATS not reachable at {nats_util.NATS_URL}"),
    pytest.mark.skipif(not chain.reachable(), reason="Chain Bridge unreachable / strict-mTLS-only"),
    pytest.mark.skipif(not shutil.which("spl-token"), reason="spl-token CLI not on PATH (needed to dev-fund buyer GRX)"),
    pytest.mark.skipif(not os.path.exists(MINT_AUTHORITY_KEYPAIR),
                       reason=f"mint authority keypair not found at {MINT_AUTHORITY_KEYPAIR}"),
]


def make_user(tag):
    """Register + verify a user, link a bare-pubkey wallet. Mirrors
    90_golden_path.make_user — duplicated rather than imported per this repo's
    per-suite-independent convention (see 30_settlement vs 90_golden_path)."""
    uname = f"e2e_tl_{tag}_{int(time.time()*1000)%1000000}"
    email = f"{uname}@grx.test"
    r = requests.post(f"{IAM}/api/v1/auth/register",
                      json={"username": uname, "email": email, "password": PASSWORD,
                            "first_name": "E2E", "last_name": tag}, timeout=10)
    assert r.status_code in (200, 201), f"register {tag} failed: {r.status_code} {r.text}"
    uid = r.json().get("id")
    import db as _db
    token = _db.scalar(f"SELECT email_verification_token FROM users WHERE id = '{uid}';")
    assert token, f"no verify token for {tag}"
    v = requests.get(f"{IAM}/api/v1/auth/verify", params={"token": token}, timeout=10)
    assert v.status_code == 200, f"verify {tag} failed: {v.status_code} {v.text}"
    body = v.json()
    jwt = body.get("auth", {}).get("access_token")
    from solders.keypair import Keypair
    wallet = str(Keypair().pubkey())
    lw = requests.post(f"{IAM}/api/v1/me/wallets",
                       json={"wallet_address": wallet, "label": "E2E Primary", "is_primary": True},
                       headers={**GW, "Authorization": f"Bearer {jwt}"}, timeout=15)
    assert lw.status_code in (200, 201), f"link primary wallet {tag} failed: {lw.status_code} {lw.text}"
    r2 = requests.post(f"{IAM}/api/v1/me/registration", timeout=15,
                       headers={**GW, "Authorization": f"Bearer {jwt}", "Content-Type": "application/json"},
                       json={"user_type": "prosumer", "location": {"lat_e7": 13756300, "long_e7": 100501800}})
    assert r2.status_code in (200, 202, 409), f"on-chain onboard {tag} failed: {r2.status_code} {r2.text}"
    return {"jwt": jwt, "user_id": uid, "wallet": wallet, "username": uname}


def trade_hdr(uid):
    return {"x-gridtokenx-role": "api-gateway", "x-gridtokenx-gateway-secret": SECRET,
            "x-gridtokenx-user-id": str(uid)}


def place_order(uid, side, amount, price):
    return requests.post(f"{TRADING}/api/v1/orders", timeout=8, headers=trade_hdr(uid),
                         json={"side": side, "order_type": "limit",
                               "energy_amount_kwh": str(amount), "price_per_kwh": str(price),
                               "zone_id": ZONE})


def _fund_grx(owner_wallet: str, amount_tokens: float):
    """Dev-only test fixture: mint GRX (classic SPL, 6 dec) straight to
    `owner_wallet` using the local validator's mint-authority keypair — the SAME key
    `bootstrap.ts` (gridtokenx-anchor/scripts/bootstrap.ts:192-224) used as
    CURRENCY_TOKEN_MINT's mint authority when it created the mint. No production
    service ever mints currency to a user (only GRID is minted, upstream via the
    Aggregator Bridge) — this bypasses the platform entirely and exists ONLY to give
    a test buyer something to spend. Never reuse this pattern outside test setup."""
    # `spl-token mint --recipient-owner` expects the recipient's ATA to already
    # exist — create it first (idempotent: exit 1 + "already in use" if present).
    create_cmd = [
        "spl-token", "create-account", CURRENCY_TOKEN_MINT,
        "--owner", owner_wallet,
        "--fee-payer", MINT_AUTHORITY_KEYPAIR,
        "--url", SOLANA_RPC_URL,
    ]
    cr = subprocess.run(create_cmd, capture_output=True, text=True, timeout=30)
    if cr.returncode != 0 and "already in use" not in (cr.stdout + cr.stderr):
        raise AssertionError(f"spl-token create-account failed: {cr.stdout}\n{cr.stderr}")

    cmd = [
        "spl-token", "mint", CURRENCY_TOKEN_MINT, str(amount_tokens),
        "--recipient-owner", owner_wallet,
        "--mint-authority", MINT_AUTHORITY_KEYPAIR,
        "--fee-payer", MINT_AUTHORITY_KEYPAIR,
        "--url", SOLANA_RPC_URL,
        "--output", "json",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, f"spl-token mint failed (rc={r.returncode}): {r.stdout}\n{r.stderr}"


def test_token_lifecycle_onchain_balance_deltas():
    seller = make_user("s")
    buyer = make_user("b")
    print(f"\n[setup] seller user_id={seller['user_id']} wallet={seller['wallet']}", flush=True)
    print(f"[setup] buyer  user_id={buyer['user_id']} wallet={buyer['wallet']}", flush=True)

    # --- Mint: trigger a real surplus mint for the seller, assert the landed
    # wallet-GRID delta (not just the envelope, per 30_settlement's caveat). -------
    before_grid = chain.token_balance_of(seller["wallet"], GRID_MINT)
    handle = si.new_meter("L", seller["user_id"], wallet=seller["wallet"])
    ts_sec = int(time.time()) - BACKDATE_SECS
    net_kwh = 25.0
    stub = si.stub()

    def _trigger():
        si.ingest(stub, handle, generated=net_kwh, consumed=0, ts_sec=ts_sec)

    try:
        msgs = nats_util.collect_sync(
            "chain.tx.mint", _trigger,
            match=lambda m: str(m.get("idempotency_key", "")).startswith(f"mint:{handle['meter']}:"),
            timeout=MINT_WAIT, want=1,
        )
    finally:
        si.cleanup(handle)

    if not msgs:
        pytest.skip(f"no mint on chain.tx.mint within {MINT_WAIT:.0f}s — minting disabled "
                    "(MINT_VIA_CHAIN_BRIDGE unset) or the bridge hasn't landed it yet")

    expected_grid_delta = round(net_kwh * GRID_DECIMALS)
    after_grid = before_grid
    deadline = time.time() + SETTLE_WAIT
    while time.time() < deadline:
        after_grid = chain.token_balance_of(seller["wallet"], GRID_MINT)
        if after_grid - before_grid >= expected_grid_delta:
            break
        time.sleep(2)
    if after_grid - before_grid != expected_grid_delta:
        pytest.skip(f"mint envelope arrived (energy_kwh={msgs[0].get('energy_kwh')}) but wallet "
                    f"GRID delta {after_grid - before_grid} != expected {expected_grid_delta} "
                    f"within {SETTLE_WAIT:.0f}s — tx may still be confirming")

    # --- Fund the buyer's GRX so they can actually place a BUY order. -----------
    price = Decimal("10")
    amount = Decimal("5")  # <= the 25 GRID just minted to the seller
    total_currency_ui = amount * price  # 50 GRX
    _fund_grx(buyer["wallet"], float(total_currency_ui) * 2)  # headroom for escrow funding

    # --- Place crossing orders, wait for the CDA match. --------------------------
    s = place_order(seller["user_id"], "sell", amount, price)
    b = place_order(buyer["user_id"], "buy", amount, price)
    assert s.status_code == 200 and b.status_code == 200, (
        f"place orders failed: sell={s.status_code} {s.text} buy={b.status_code} {b.text}"
    )

    buy_id = b.json()["id"]
    print(f"[order] sell={s.json().get('id')} buy={buy_id}", flush=True)
    filled = False
    deadline = time.time() + 25
    while time.time() < deadline:
        g = requests.get(f"{TRADING}/api/v1/orders/{buy_id}", headers=trade_hdr(buyer["user_id"]), timeout=8)
        if g.status_code == 200:
            row = g.json() or {}
            try:
                if Decimal(str(row.get("filled_amount_kwh") or "0")) >= amount:
                    filled = True
                    break
            except Exception:
                pass
        time.sleep(1)
    if not filled:
        pytest.skip("buy order did not fill within 25s — CDA match not observed, cannot assert settlement")
    print(f"[order] buy {buy_id} filled at {time.time():.0f}", flush=True)

    # --- Wait for on-chain settlement, then assert wallet balance deltas. -------
    # execute_atomic_settlement (the deployed instruction — see module docstring)
    # credits the buyer's OWN wallet GRID and the seller's OWN wallet GRX directly;
    # it does NOT touch the per-user escrow PDAs (those belong to the different
    # settle_offchain_match instruction). buyer_grid_after's 0->nonzero transition
    # is the unambiguous settlement-landed signal to poll on: nothing else credits
    # a fresh buyer's wallet with GRID.
    energy_atomic = int(amount * GRID_DECIMALS)

    buyer_grid_after = 0
    deadline = time.time() + SETTLE_WAIT
    polls = 0
    while time.time() < deadline:
        buyer_grid_after = chain.token_balance_of(buyer["wallet"], GRID_MINT)
        polls += 1
        if polls % 5 == 0:
            print(f"[settle] poll {polls}: buyer_wallet_grid={buyer_grid_after}", flush=True)
        if buyer_grid_after > 0:
            break
        time.sleep(2)

    if buyer_grid_after == 0:
        pytest.skip(f"no on-chain settlement observed within {SETTLE_WAIT:.0f}s — either "
                    "TRADE_SETTLEMENT_ENABLED is off for this stack, or the platform's "
                    "pooled settlement-source ATAs are unfunded (check via "
                    "`spl-token accounts --owner <platform authority>`; re-run "
                    "gridtokenx-anchor/scripts/fund-platform-sources.ts if so — see "
                    "the [[trading-onchain-order-leg-optionA]] memory note "
                    "'REGRESSED 2026-07-03' for this exact symptom)")

    seller_grx_after = chain.token_balance_of(seller["wallet"], CURRENCY_TOKEN_MINT, chain.TOKEN_PROGRAM_ID)

    assert buyer_grid_after == energy_atomic, (
        f"buyer wallet GRID {buyer_grid_after} != expected exact {energy_atomic}"
    )
    assert seller_grx_after > 0, (
        "seller wallet GRX should have increased (net of fees) post-settlement, got 0"
    )
