"""GridTokenX E2E — the user's lifecycle, proven end to end with a real balance:

    register -> verify (custodial wallet provisioned) -> on-chain user PDA
    -> register meter (device key + meter->user) -> signed generation readings
    -> SettlementEngine flush -> mint_generation -> GRID lands in wallet owner ATA

Unlike suite 90 (which only greps logs for the mint), this asserts the owner's
GRID token balance actually increases — the real "minting to wallet owner".

Run:  cd tests/e2e && python flow_register_to_mint.py
Needs: IAM + Aggregator Bridge + Chain Bridge up, Solana validator live, Redis up.
"""
import datetime
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))

import requests

import chain
import crypto
import db
import redis_util

IAM = os.getenv("IAM_URL", "http://localhost:4010")
ORACLE = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
PASSWORD = os.getenv("E2E_PASSWORD", "GRX-Secure-P@ss-2026-E2E")
SECRET = os.getenv("GATEWAY_SECRET", "gridtokenx-gateway-secret-2025")
ENERGY_TOKEN_PROGRAM = os.getenv(
    "SOLANA_ENERGY_TOKEN_PROGRAM_ID", "6FZKcVKCLFSNLMxypFJGU4K14xUBnxNW9VAuKGhmqjGX"
)
GW = {"x-gridtokenx-role": "api-gateway", "x-gridtokenx-gateway-secret": SECRET}


def step(msg):
    print(f"\n=== {msg} ===")


def fail(msg):
    print(f"  ❌ {msg}")
    sys.exit(1)


def ok(msg):
    print(f"  ✅ {msg}")


def main():
    tag = int(time.time() * 1000) % 1_000_000

    # --- 1. register ----------------------------------------------------
    step("1. register")
    uname = f"flow_{tag}"
    email = f"{uname}@grx.test"
    r = requests.post(f"{IAM}/api/v1/auth/register",
                      json={"username": uname, "email": email, "password": PASSWORD,
                            "first_name": "Flow", "last_name": "Test"}, timeout=10)
    if r.status_code not in (200, 201):
        fail(f"register: {r.status_code} {r.text}")
    uid = r.json().get("id")
    ok(f"registered user_id={uid}")

    # --- 2. verify email -> custodial wallet ----------------------------
    step("2. verify email (custodial wallet auto-provision)")
    token = db.scalar(f"SELECT email_verification_token FROM users WHERE id = '{uid}';")
    if not token:
        fail("no email_verification_token in DB")
    # 60s: verify provisions a custodial wallet (PBKDF2 600k-iter encrypt) then
    # registers the user on-chain and polls ~15s for the PDA to confirm.
    v = requests.get(f"{IAM}/api/v1/auth/verify", params={"token": token}, timeout=60)
    if v.status_code != 200:
        fail(f"verify: {v.status_code} {v.text}")
    body = v.json()
    jwt = body.get("auth", {}).get("access_token")
    wallet = body.get("wallet_address")
    if not wallet:
        fail(f"verify returned no wallet_address (custodial provision failed): {body}")
    ok(f"verified; custodial wallet = {wallet}")

    # --- 3a. on-chain user PDA onboard ----------------------------------
    step("3a. on-chain user onboard (user PDA via Registry)")
    o = requests.post(f"{IAM}/api/v1/users/me/onchain-profile", timeout=30,
                      headers={**GW, "Authorization": f"Bearer {jwt}",
                               "Content-Type": "application/json"},
                      json={"user_type": "prosumer",
                            "location": {"lat_e7": 13756300, "long_e7": 100501800}})
    print(f"  onboard -> {o.status_code} {o.text}")
    ob = o.json() if o.headers.get("content-type", "").startswith("application/json") else {}
    if o.status_code not in (200, 202) or ob.get("status") == "failed":
        fail(f"on-chain onboard did not confirm: {o.status_code} {o.text}")
    ok(f"onboard status={ob.get('status')} sig={ob.get('transaction_signature')}")

    # --- 3b. register meter (device key + meter->user) ------------------
    step("3b. register meter (Ed25519 device key + meter->user map)")
    priv, pub_hex = crypto.new_identity()
    meter = f"FLOW-METER-{tag}"
    redis_util.register_device_key(meter, pub_hex)
    redis_util.register_meter(meter, uid)
    ok(f"meter {meter} -> user {uid}")

    # --- 4. signed generation readings ----------------------------------
    step("4. send signed generation readings")
    mint_pda = chain.grid_mint_pda(ENERGY_TOKEN_PROGRAM)
    before = chain.token_balance_of(wallet, mint_pda)
    print(f"  GRID mint PDA = {mint_pda}")
    print(f"  owner GRID balance BEFORE = {before}")

    base = int((time.time() - 25 * 60) * 1000)  # backdated -> closed 15-min window
    accepted = 0
    for i in range(3):
        sig = crypto.sign_telemetry(priv, meter, 10.0, base + i * 1000)
        dt = datetime.datetime.fromtimestamp((base + i * 1000) / 1000, tz=datetime.timezone.utc)
        iso = dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")
        rr = requests.post(f"{ORACLE}/v1/private-network/ingest", timeout=8,
            headers={"X-API-KEY": os.getenv("AGGREGATOR_API_KEY", "e2e-test-key")},
            json={
            "protocol": "dlms", "device_id": meter,
            "payload": {"device_id": meter, "timestamp": iso, "kwh": 10.0,
                        "energy_generated": 10.0, "energy_consumed": 0.0, "signature": sig}})
        if rr.status_code in (200, 202):
            accepted += 1
        else:
            print(f"  reading {i} rejected: {rr.status_code} {rr.text}")
    if accepted != 3:
        fail(f"only {accepted}/3 readings accepted")
    ok("3 generation readings accepted (30 kWh total)")

    # --- 5. wait for settlement -> mint -> balance increase -------------
    step("5. wait for settlement engine flush + mint_generation -> wallet ATA")
    deadline = time.time() + 240  # settlement loop is 60s; allow a few cycles + confirm
    after = before
    while time.time() < deadline:
        after = chain.token_balance_of(wallet, mint_pda)
        if after > before:
            break
        print(f"  ... balance still {after}, waiting ({int(deadline - time.time())}s left)")
        time.sleep(15)

    if after > before:
        decimals = 9
        ok(f"MINT LANDED: GRID balance {before} -> {after} "
           f"(+{(after - before) / 10**decimals} GRID) in owner ATA")
        print("\n🎉 register -> verify -> wallet -> meter -> mint-to-owner: COMPLETE")
    else:
        fail(f"no mint after 240s: balance stayed {after}. "
             f"Check aggregator settlement + chain-bridge logs.")


if __name__ == "__main__":
    main()
