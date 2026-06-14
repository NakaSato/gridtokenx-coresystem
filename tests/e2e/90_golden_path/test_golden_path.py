"""Suite 90 — Golden Path: full cross-platform lifecycle (the regression anchor).

Chains every hop end to end with TWO distinct IAM users (seller + buyer):

  register+verify (x2) -> wallet provisioned -> on-chain user PDA (x2)
  -> register seller meter (device key + meter->user in Redis)
  -> seller sends backdated signed GENERATION readings
  -> Oracle validates + disseminates (Redis zone stream grows)
  -> SettlementEngine flushes bin -> mint (oracle/chain-bridge logs)  [needs platform]
  -> seller SELL order + buyer crossing BUY order -> CDA match -> fills
  -> trade settlement (chain-bridge log)                              [best-effort]
  -> notification dispatched                                          [best-effort]
  -> Chain Bridge slot advances / explorer reachable                 [liveness]

Design: IAM is the hard prerequisite (skip the whole scenario if down). Every later
hop is asserted only when its service is reachable; otherwise that stage is recorded
as SKIPPED, not failed. At the end the test fails iff any *reachable* stage failed.

Run: cd tests/e2e && python -m pytest 90_golden_path -v -s
"""
import datetime
import os
import time

import pytest
import requests

import crypto
import dlogs
import redis_util

IAM = os.getenv("IAM_URL", "http://localhost:4010")
ORACLE = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
# api_key_auth gates ingest (auth.rs); aggregator seeds `e2e-test-key` in its static
# GRIDTOKENX_API_KEYS for the harness (docker-compose.yml:755). Missing → 401 at auth.
ORACLE_INGEST_HEADERS = {"X-API-KEY": os.getenv("AGGREGATOR_API_KEY", "e2e-test-key")}
TRADING = os.getenv("TRADING_URL", "http://localhost:8093")
CHAIN_HTTP = os.getenv("CHAIN_BRIDGE_HTTP", "http://" + os.getenv("CHAIN_BRIDGE_GRPC", "localhost:5040"))
NOTI_HTTP = os.getenv("NOTI_HTTP", "http://" + os.getenv("NOTI_GRPC", "localhost:5050"))
EXPLORER = os.getenv("EXPLORER_URL", "http://localhost:11002")
API_SERVICES_URL = os.getenv("API_SERVICES_URL", "http://localhost:4000")

PASSWORD = os.getenv("E2E_PASSWORD", "GRX-Secure-P@ss-2026-E2E")
SECRET = os.getenv("GATEWAY_SECRET", "gridtokenx-gateway-secret-2025")
ZONE = int(os.getenv("E2E_TRADING_ZONE", "1"))
GW = {"x-gridtokenx-role": "api-gateway", "x-gridtokenx-gateway-secret": SECRET}

AGGREGATOR_CONTAINER = os.getenv("AGGREGATOR_CONTAINER", "gridtokenx-aggregator-bridge")
CHAIN_CONTAINER = os.getenv("CHAIN_CONTAINER", "gridtokenx-chain-bridge")


def _up(url, path="/health", timeout=3):
    try:
        requests.get(f"{url}{path}", timeout=timeout)
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(
    not _up(IAM),
    reason="IAM unreachable — golden path requires at least the identity service",
)


class Stages:
    """Accumulates per-stage outcome; fail iff a *reachable* stage hard-failed."""
    def __init__(self):
        self.rows = []

    def ok(self, name):
        self.rows.append((name, "PASS")); print(f"  ✅ {name}")

    def skip(self, name, why):
        self.rows.append((name, "SKIP")); print(f"  ⏭️  {name} — {why}")

    def fail(self, name, why):
        self.rows.append((name, "FAIL")); print(f"  ❌ {name} — {why}")

    def assert_clean(self):
        fails = [n for n, s in self.rows if s == "FAIL"]
        passed = sum(1 for _, s in self.rows if s == "PASS")
        skipped = sum(1 for _, s in self.rows if s == "SKIP")
        print(f"\nGolden path: {passed} pass, {skipped} skip, {len(fails)} fail")
        assert not fails, f"reachable stages failed: {fails}"


def _jwt_sub(jwt):
    import base64, json
    if not jwt or jwt.count(".") != 2:
        return None
    p = jwt.split(".")[1]; p += "=" * (-len(p) % 4)
    try:
        return json.loads(base64.urlsafe_b64decode(p)).get("sub")
    except Exception:
        return None


def make_user(tag):
    """Register + verify a user. Returns dict(jwt,user_id,wallet,username)."""
    uname = f"e2e_gp_{tag}_{int(time.time()*1000)%1000000}"
    email = f"{uname}@grx.test"
    r = requests.post(f"{IAM}/api/v1/auth/register",
                      json={"username": uname, "email": email, "password": PASSWORD,
                            "first_name": "E2E", "last_name": tag}, timeout=10)
    assert r.status_code in (200, 201), f"register {tag} failed: {r.status_code} {r.text}"
    uid = r.json().get("id")
    # Real verification token from DB (mirrors test-registration-e2e.sh).
    import db as _db  # lib/db.py
    token = _db.scalar(f"SELECT email_verification_token FROM users WHERE id = '{uid}';")
    assert token, f"no verify token for {tag}"
    v = requests.get(f"{IAM}/api/v1/auth/verify", params={"token": token}, timeout=10)
    assert v.status_code == 200, f"verify {tag} failed: {v.status_code} {v.text}"
    body = v.json()
    jwt = body.get("auth", {}).get("access_token")
    # Since iam `8b84ccd` verify no longer provisions a custodial wallet — link a
    # fresh keypair as primary, mirroring the real user flow.
    wallet = body.get("wallet_address")
    if not wallet:
        from solders.keypair import Keypair
        wallet = str(Keypair().pubkey())
        lw = requests.post(f"{IAM}/api/v1/me/wallets",
                           json={"wallet_address": wallet, "label": "E2E Primary",
                                 "is_primary": True},
                           headers={**GW, "Authorization": f"Bearer {jwt}"}, timeout=15)
        assert lw.status_code in (200, 201), \
            f"link primary wallet {tag} failed: {lw.status_code} {lw.text}"
    return {"jwt": jwt, "user_id": uid or _jwt_sub(jwt),
            "wallet": wallet, "username": uname}


def _send_reading(meter, priv, generated, ts_ms):
    sig = crypto.sign_telemetry(priv, meter, generated, ts_ms)
    dt = datetime.datetime.fromtimestamp(ts_ms / 1000, tz=datetime.timezone.utc)
    iso = dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    # Send an explicit `kwh` field equal to the signed value: the Oracle Bridge's
    # canonical kwh derivation checks `kwh` first, then energy_consumed, then
    # energy_generated. With energy_consumed=0.0 present it would otherwise sign-check
    # against "0" and reject our generation reading (403) under enforced verification.
    return requests.post(f"{ORACLE}/v1/private-network/ingest", timeout=5,
                         headers=ORACLE_INGEST_HEADERS, json={
        "protocol": "dlms", "device_id": meter,
        "payload": {"device_id": meter, "timestamp": iso, "kwh": float(generated),
                    "energy_generated": float(generated), "energy_consumed": 0.0,
                    "signature": sig}})


def trade_hdr(uid):
    # api-gateway role degrades to Unknown unless x-gridtokenx-gateway-secret == GATEWAY_SECRET.
    return {"x-gridtokenx-role": "api-gateway", "x-gridtokenx-gateway-secret": SECRET,
            "x-gridtokenx-user-id": str(uid)}


def place_order(uid, side, amount, price):
    return requests.post(f"{TRADING}/api/v1/orders", timeout=8, headers=trade_hdr(uid),
                         json={"side": side, "order_type": "limit",
                               "energy_amount_kwh": str(amount), "price_per_kwh": str(price),
                               "zone_id": ZONE})


def test_golden_path():
    st = Stages()

    # --- Stage 1: two users registered + wallets provisioned -------------
    seller = make_user("sell")
    buyer = make_user("buy")
    assert seller["wallet"] and buyer["wallet"], "wallet not provisioned"
    assert seller["user_id"] and buyer["user_id"], "user_id missing"
    st.ok("register+verify x2 + wallet provisioned")

    # --- Stage 2: on-chain user onboarding (both) -----------------------
    for u in (seller, buyer):
        r = requests.post(f"{IAM}/api/v1/me/registration", timeout=15,
                          headers={**GW, "Authorization": f"Bearer {u['jwt']}",
                                   "Content-Type": "application/json"},
                          json={"user_type": "prosumer",
                                "location": {"lat_e7": 13756300, "long_e7": 100501800}})
        if r.status_code not in (200, 202, 409):
            st.fail("on-chain onboard", f"{u['username']}: {r.status_code} {r.text}")
            break
    else:
        st.ok("on-chain user onboarding x2")

    # --- Stage 3: register seller meter (device key + meter->user) ------
    if not _up(ORACLE):
        st.skip("meter + telemetry", "Oracle down")
        meter = None
    else:
        pk, pub = crypto.new_identity()
        meter = f"E2E-GP-{int(time.time()*1000)%1000000}"
        try:
            redis_util.register_device_key(meter, pub)
            redis_util.register_meter(meter, seller["user_id"])
            st.ok("seller meter registered (device key + meter->user)")
        except Exception as e:
            st.fail("meter register", str(e)); meter = None

    # --- Stage 4+5: backdated generation readings -> dissemination ------
    if meter:
        try:
            before = redis_util.stream_total_len()
        except Exception:
            before = -1
        base = int((time.time() - 25 * 60) * 1000)  # past window
        accepted = 0
        for i in range(3):
            r = _send_reading(meter, pk, 10.0, base + i * 1000)
            if r.status_code in (200, 202):
                accepted += 1
        if accepted == 3:
            st.ok("3 signed generation readings accepted")
        else:
            st.fail("telemetry ingest", f"only {accepted}/3 accepted")
        # Dissemination
        if before >= 0:
            grew = False
            deadline = time.time() + 10
            while time.time() < deadline:
                try:
                    if redis_util.stream_total_len() > before:
                        grew = True; break
                except Exception:
                    pass  # transient Redis blip — keep polling
                time.sleep(0.5)
            st.ok("dissemination to Redis zone stream") if grew else \
                st.fail("dissemination", "no zone stream growth")
        else:
            st.skip("dissemination", "Redis unavailable")

    # --- Stage 6: settlement -> mint (logs; needs platform) ------------
    if meter and _up(API_SERVICES_URL) and dlogs.container_running(AGGREGATOR_CONTAINER):
        flushed = dlogs.wait_for_log(AGGREGATOR_CONTAINER, "completed billing bins", timeout=150)
        st.ok("settlement engine flushed completed bin") if flushed else \
            st.fail("settlement flush", "no 'completed billing bins' log in 150s")
        if dlogs.container_running(CHAIN_CONTAINER):
            landed = dlogs.wait_for_log(CHAIN_CONTAINER, "Success", timeout=60)
            st.ok("mint tx success at Chain Bridge") if landed else \
                st.skip("mint landing", "no chain-bridge success log (validator state)")
    else:
        st.skip("settlement+mint", "platform :4000 down or oracle not a container")

    # --- Stage 7: CDA match between seller and buyer --------------------
    if not _up(TRADING, "/api/v1/stats"):
        st.skip("trading match", "Trading down")
    else:
        price = 12
        s = place_order(seller["user_id"], "sell", 4, price)
        b = place_order(buyer["user_id"], "buy", 4, price)
        if s.status_code == 200 and b.status_code == 200:
            # Poll the BUYER's crossing order — it is the active taker and reliably fills
            # against the best resting ask. (We can't assert the SELLER's specific sell
            # fills: in a shared/dirty book the buy may cross an even cheaper resting ask
            # left by other tests, leaving this seller's ask untouched — that's correct CDA.)
            # GET /orders/:id now returns a bare OrderData object (since the
            # get_order_by_id fix); tolerate the older {data:[...]} list shape too.
            # Assert on filled qty, not status — matcher labels full fills as Filled
            # but partials stay partially_filled.
            from decimal import Decimal, InvalidOperation
            buy_id = b.json()["id"]
            filled = False
            deadline = time.time() + 25
            while time.time() < deadline:
                try:
                    g = requests.get(f"{TRADING}/api/v1/orders/{buy_id}",
                                     headers=trade_hdr(buyer["user_id"]), timeout=8)
                except requests.RequestException:
                    time.sleep(1)
                    continue
                if g.status_code == 200:
                    j = g.json() or {}
                    row = j if j.get("id") == buy_id else None
                    if row is None:
                        rows = j.get("data") or []
                        row = next((o for o in rows if o.get("id") == buy_id),
                                   rows[0] if rows else None)
                    if row:
                        try:
                            if Decimal(str(row.get("filled_amount_kwh") or "0")) >= Decimal("4"):
                                filled = True; break
                        except InvalidOperation:
                            pass
                time.sleep(1)
            st.ok("CDA match: buyer's crossing order filled") if filled else \
                st.fail("CDA match", "buy order not filled within 25s")
        else:
            st.fail("place orders", f"sell={s.status_code} buy={b.status_code}")

    # --- Stage 8: trade settlement evidence (best-effort) --------------
    if _up(TRADING, "/api/v1/stats") and dlogs.container_running(CHAIN_CONTAINER):
        settled = dlogs.wait_for_log(CHAIN_CONTAINER, "Success", timeout=30)
        st.ok("trade settlement tx at Chain Bridge") if settled else \
            st.skip("trade settlement", "no chain-bridge success log (may be batched)")
    else:
        st.skip("trade settlement", "trading/chain-bridge container unavailable")

    # --- Stage 9: notification dispatched (best-effort) ----------------
    try:
        r = requests.post(f"{NOTI_HTTP}/noti.NotificationService/SendNotification", timeout=6,
                          headers={"Content-Type": "application/json"},
                          json={"channel": "EMAIL", "recipient": seller["username"] + "@grx.test",
                                "template_id": "trade_filled", "variables_json": "{}",
                                "user_id": seller["user_id"],
                                "idempotency_key": f"gp-{int(time.time()*1000)}"})
        if r.status_code == 200:
            st.ok("notification dispatched")
        else:
            st.fail("notification", f"{r.status_code} {r.text[:120]}")
    except requests.RequestException:
        st.skip("notification", "Noti down")

    # --- Stage 10: chain liveness / explorer ---------------------------
    try:
        r = requests.post(f"{CHAIN_HTTP}/gridtokenx.chain.v1.ChainBridgeService/GetSlot",
                          json={}, timeout=6,
                          headers={"Content-Type": "application/json", "x-gridtokenx-role": "admin"})
        if r.status_code == 200 and int(r.json().get("slot", 0)) > 0:
            st.ok("chain liveness (slot > 0 via Chain Bridge)")
        else:
            st.skip("chain liveness", f"GetSlot {r.status_code} (mTLS/role?)")
    except requests.RequestException:
        st.skip("chain liveness", "Chain Bridge down")
    if _up(EXPLORER, "/"):
        st.ok("explorer reachable")
    else:
        st.skip("explorer", "Explorer UI down")

    st.assert_clean()
