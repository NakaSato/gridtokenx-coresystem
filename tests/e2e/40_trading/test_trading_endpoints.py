"""Suite 40 — Trading Service: previously-UNCOVERED REST + gRPC endpoints.

Companion to test_trading.py (which covers order place/match/cancel). This file
exercises the read-only market endpoints, quotes, trade history/export, the
price-alert and recurring-order CRUD lifecycles, and gRPC ListOrders/GetOrder/
CancelOrder parity.

AUTH (same as test_trading.py — trading-service trusts gateway-injected headers,
does NOT validate the JWT itself; submit/read all require ApiGateway|Admin):
  x-gridtokenx-role           : api-gateway
  x-gridtokenx-gateway-secret : <GATEWAY_SECRET>   (else role degrades -> 401)
  x-gridtokenx-user-id        : <uuid>             (UserContext — owner scoping)
We derive user-id from the IAM-issued JWT `sub` via the conftest `new_user` fixture.

Several endpoints return MOCK / config-derived data (e.g. /quotes, /stats,
/markets/config) — we assert on response SHAPE + types + 200, not business values
(verified against gridtokenx-trading-service crates/trading-api/src/rest.rs).

Run: cd tests/e2e && uv run --no-project python -m pytest 40_trading/test_trading_endpoints.py -v
"""
import os
import time
from decimal import Decimal

import pytest
import requests

TRADING = os.getenv("TRADING_URL", "http://localhost:8093")
ZONE = int(os.getenv("E2E_TRADING_ZONE", "1"))
GATEWAY_SECRET = os.getenv("GATEWAY_SECRET", "gridtokenx-gateway-secret-2025")


def _up():
    try:
        requests.get(f"{TRADING}/api/v1/stats", timeout=3)
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(not _up(), reason="Trading Service unreachable")


def hdr(user_id, role="api-gateway"):
    """Gateway auth headers — mirrors test_trading.py.hdr exactly."""
    h = {"x-gridtokenx-role": role, "x-gridtokenx-user-id": str(user_id)}
    if role == "api-gateway":
        h["x-gridtokenx-gateway-secret"] = GATEWAY_SECRET
    return h


def place_order(user_id, side, amount, price, zone=ZONE):
    """POST /api/v1/orders — same body shape as test_trading.py.place_order
    (rest.rs SubmitOrderRequest:25 — side, order_type, energy_amount_kwh,
    price_per_kwh as STRING decimals, zone_id as int)."""
    body = {"side": side, "order_type": "limit",
            "energy_amount_kwh": str(amount), "price_per_kwh": str(price), "zone_id": zone}
    return requests.post(f"{TRADING}/api/v1/orders", json=body, headers=hdr(user_id), timeout=8)


# =============================================================================
# Read-only market endpoints — deterministic shape + 200 (auth-gated)
# =============================================================================

def test_zone_book_shape(new_user):
    """GET /api/v1/zones/{zone_id}/book (rest.rs get_order_book:268).
    OrderBookResponse:43 — {zone_id:i32, last_update_id:u64, asks:[[str,str]],
    bids:[[str,str]]}. Aggregated from real active orders by price level."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.get(f"{TRADING}/api/v1/zones/{ZONE}/book", headers=hdr(uid), timeout=8)
    assert r.status_code == 200, f"{r.status_code} {r.text}"
    j = r.json()
    assert j["zone_id"] == ZONE
    assert isinstance(j["last_update_id"], int)
    assert isinstance(j["asks"], list) and isinstance(j["bids"], list)
    # Levels are [price, amount] string pairs when present.
    for level in j["asks"] + j["bids"]:
        assert isinstance(level, list) and len(level) == 2
        assert all(isinstance(x, str) for x in level)


def test_zone_book_requires_role(new_user):
    """get_order_book:273 require_any(ApiGateway|Admin) — no secret -> 401."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.get(f"{TRADING}/api/v1/zones/{ZONE}/book",
                     headers={"x-gridtokenx-role": "api-gateway",
                              "x-gridtokenx-user-id": str(uid)}, timeout=8)
    assert r.status_code in (401, 403), f"unguarded book read: {r.status_code}"


def test_matching_status_shape(new_user):
    """GET /api/v1/markets/matching-status (rest.rs get_matching_status:876).
    MatchingStatusResponse:819 — counts (usize), buy/sell PriceRange{min,max:f64},
    can_match:bool, match_reason:str. Live aggregation over active orders."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.get(f"{TRADING}/api/v1/markets/matching-status", headers=hdr(uid), timeout=8)
    assert r.status_code == 200, f"{r.status_code} {r.text}"
    j = r.json()
    for k in ("pending_buy_orders", "pending_sell_orders", "pending_matches"):
        assert isinstance(j[k], int), f"{k} not int: {j[k]!r}"
    for rng in ("buy_price_range", "sell_price_range"):
        assert set(j[rng].keys()) == {"min", "max"}
        assert isinstance(j[rng]["min"], (int, float))
        assert isinstance(j[rng]["max"], (int, float))
    assert isinstance(j["can_match"], bool)
    assert isinstance(j["match_reason"], str) and j["match_reason"]


def test_market_stats_shape(new_user):
    """GET /api/v1/markets/stats -> get_market_stats (rest.rs:475, MOCK).
    NOTE: only /api/v1/stats is routed to this handler (startup.rs:99). There is
    NO /api/v1/markets/stats route, so hit the registered path. MarketStatsResponse:465
    — timestamp, total_volume_24h_kwh/avg_price_24h (str), active_users:u32,
    grid_stability_index/renewable_ratio (str)."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.get(f"{TRADING}/api/v1/stats", headers=hdr(uid), timeout=8)
    assert r.status_code == 200, f"{r.status_code} {r.text}"
    j = r.json()
    assert isinstance(j["timestamp"], str)
    for k in ("total_volume_24h_kwh", "avg_price_24h", "grid_stability_index", "renewable_ratio"):
        assert isinstance(j[k], str), f"{k} expected str decimal: {j[k]!r}"
    assert isinstance(j["active_users"], int)


def test_p2p_orderbook_shape(new_user):
    """GET /api/v1/markets/orderbook (rest.rs get_p2p_orderbook:1022).
    P2POrderBookResponse:960 — {asks:[[str,str]], bids:[[str,str]]} aggregate
    over ALL active orders (cross-zone)."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.get(f"{TRADING}/api/v1/markets/orderbook", headers=hdr(uid), timeout=8)
    assert r.status_code == 200, f"{r.status_code} {r.text}"
    j = r.json()
    assert set(j.keys()) >= {"asks", "bids"}
    for level in j["asks"] + j["bids"]:
        assert isinstance(level, list) and len(level) == 2
        assert all(isinstance(x, str) for x in level)


def test_market_config_shape(new_user):
    """GET /api/v1/markets/config (rest.rs get_market_config:831).
    MarketConfigResponse:793 — all f64 pricing params + transaction_fee_bps:u32."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.get(f"{TRADING}/api/v1/markets/config", headers=hdr(uid), timeout=8)
    assert r.status_code == 200, f"{r.status_code} {r.text}"
    j = r.json()
    for k in ("base_price_thb_kwh", "grid_import_price_thb_kwh", "grid_export_price_thb_kwh",
              "min_price_per_kwh", "max_price_per_kwh"):
        assert isinstance(j[k], (int, float)), f"{k} not numeric: {j[k]!r}"
    assert isinstance(j["transaction_fee_bps"], int)


def test_p2p_market_prices_shape(new_user):
    """GET /api/v1/markets/p2p/market-prices (rest.rs get_p2p_market_prices:850).
    P2PMarketPricesResponse:803 — f64 prices, loss_allocation_model:str, and
    wheeling_charges/loss_factors maps keyed intra_zone/cross_zone (rest.rs:858)."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.get(f"{TRADING}/api/v1/markets/p2p/market-prices", headers=hdr(uid), timeout=8)
    assert r.status_code == 200, f"{r.status_code} {r.text}"
    j = r.json()
    assert isinstance(j["base_price_thb_kwh"], (int, float))
    assert isinstance(j["loss_allocation_model"], str)
    for m in ("wheeling_charges", "loss_factors"):
        assert isinstance(j[m], dict)
        assert {"intra_zone", "cross_zone"} <= set(j[m].keys()), f"{m} keys: {j[m].keys()}"
        assert all(isinstance(v, (int, float)) for v in j[m].values())


# =============================================================================
# Quotes — POST /api/v1/quotes (MOCK breakdown, rest.rs create_quote:439)
# =============================================================================

def test_create_quote_shape(new_user):
    """POST /api/v1/quotes (rest.rs create_quote:439, MOCK).
    QuoteRequest:83 — buyer_zone_id/seller_zone_id:i32, energy_amount_kwh/agreed_price
    (str). QuoteResponse:91 — quote_id (q_<8hex>), expires_at, breakdown{4 str},
    grid_metrics{effective_energy_kwh/loss_factor/zone_distance_km str, is_grid_compliant bool}."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    body = {"buyer_zone_id": ZONE, "seller_zone_id": ZONE + 1,
            "energy_amount_kwh": "100", "agreed_price": "4.5"}
    r = requests.post(f"{TRADING}/api/v1/quotes", json=body, headers=hdr(uid), timeout=8)
    assert r.status_code == 200, f"{r.status_code} {r.text}"
    j = r.json()
    assert j["quote_id"].startswith("q_")
    assert isinstance(j["expires_at"], str)
    bk = j["breakdown"]
    assert {"energy_cost", "wheeling_charge", "loss_cost", "total_cost"} == set(bk.keys())
    assert all(isinstance(v, str) for v in bk.values())
    gm = j["grid_metrics"]
    for k in ("effective_energy_kwh", "loss_factor", "zone_distance_km"):
        assert isinstance(gm[k], str)
    assert isinstance(gm["is_grid_compliant"], bool)


def test_create_quote_requires_role(new_user):
    """create_quote:443 require_any — missing secret -> 401."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    body = {"buyer_zone_id": ZONE, "seller_zone_id": ZONE,
            "energy_amount_kwh": "1", "agreed_price": "1"}
    r = requests.post(f"{TRADING}/api/v1/quotes", json=body,
                      headers={"x-gridtokenx-role": "api-gateway",
                               "x-gridtokenx-user-id": str(uid)}, timeout=8)
    assert r.status_code in (401, 403), f"unguarded quote: {r.status_code}"


# =============================================================================
# Trade history (JSON) + export (CSV/JSON) — backed by settlements table
# =============================================================================

def test_trades_history_shape(new_user):
    """GET /api/v1/trades (rest.rs get_trades:1186). TradesListResponse:1085 —
    {trades:[...], total_count:i64, total:i64}. A fresh user has no settlements,
    so we assert the empty-but-well-formed envelope (shape, not business values)."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.get(f"{TRADING}/api/v1/trades?limit=10", headers=hdr(uid), timeout=8)
    assert r.status_code == 200, f"{r.status_code} {r.text}"
    j = r.json()
    assert isinstance(j["trades"], list)
    assert isinstance(j["total_count"], int)
    assert isinstance(j["total"], int)
    # Fresh user: no trades yet.
    assert j["total"] == 0 and j["trades"] == [], f"unexpected trades for fresh user: {j}"


def test_trades_export_csv_default(new_user):
    """GET /api/v1/trades/export (rest.rs export_trades:1213) defaults to CSV.
    Content-Type text/csv + attachment disposition (rest.rs:1248); the header row
    (rest.rs trades_to_csv:1156) is always emitted even with zero rows."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.get(f"{TRADING}/api/v1/trades/export", headers=hdr(uid), timeout=8)
    assert r.status_code == 200, f"{r.status_code} {r.text}"
    assert "text/csv" in r.headers.get("content-type", "").lower(), r.headers
    assert "attachment" in r.headers.get("content-disposition", "").lower()
    first_line = r.text.splitlines()[0] if r.text.splitlines() else ""
    assert first_line.startswith("id,executed_at,role,counterparty_id,quantity,price"), \
        f"unexpected CSV header: {first_line!r}"


def test_trades_export_json_format(new_user):
    """GET /api/v1/trades/export?format=json (rest.rs:1241) returns a JSON array
    of trade records (empty for a fresh user)."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.get(f"{TRADING}/api/v1/trades/export?format=json", headers=hdr(uid), timeout=8)
    assert r.status_code == 200, f"{r.status_code} {r.text}"
    body = r.json()
    assert isinstance(body, list), f"expected JSON array, got {type(body)}"
    assert body == [], f"fresh user should have no exported trades: {body}"


# =============================================================================
# Price-alerts CRUD lifecycle — POST -> GET list -> DELETE (assert appears/gone)
# =============================================================================

def test_price_alert_crud_lifecycle(new_user):
    """POST (rest.rs create_price_alert:1298) -> GET list (list_price_alerts:1351)
    -> DELETE {id} (delete_price_alert:1374).

    CreatePriceAlertRequest:1263 — {symbol?, target_price:str, condition}.
    PriceAlertResponse:1272 — {id, user_id, symbol (echoes note), target_price:str,
    condition, is_active:bool, created_at}. DELETE returns {success:true}; a second
    DELETE of the same id -> 404 (delete_price_alert:1396)."""
    uid = new_user["user_id"] or pytest.skip("no user_id")

    # CREATE
    create = requests.post(f"{TRADING}/api/v1/price-alerts",
                           json={"symbol": "GRID", "target_price": "12.5", "condition": "above"},
                           headers=hdr(uid), timeout=8)
    assert create.status_code == 200, f"create alert: {create.status_code} {create.text}"
    a = create.json()
    alert_id = a["id"]
    assert a["user_id"] == str(uid), f"alert owner mismatch: {a['user_id']} != {uid}"
    assert a["symbol"] == "GRID"           # note -> symbol (rest.rs:1289)
    # target_price is a STRING decimal; rust_decimal preserves scale ("12.50000000"),
    # so compare numerically rather than by exact string.
    assert isinstance(a["target_price"], str)
    assert Decimal(a["target_price"]) == Decimal("12.5")
    assert a["condition"] == "above"       # AlertCondition lowercase
    assert a["is_active"] is True          # new alert is Active (rest.rs:1292)

    # LIST — created alert appears
    lst = requests.get(f"{TRADING}/api/v1/price-alerts", headers=hdr(uid), timeout=8)
    assert lst.status_code == 200, f"list alerts: {lst.status_code} {lst.text}"
    alerts = lst.json()
    assert isinstance(alerts, list)
    assert any(x["id"] == alert_id for x in alerts), "created alert missing from list"

    # DELETE
    dele = requests.delete(f"{TRADING}/api/v1/price-alerts/{alert_id}", headers=hdr(uid), timeout=8)
    assert dele.status_code == 200, f"delete alert: {dele.status_code} {dele.text}"
    assert dele.json().get("success") is True

    # LIST — alert is gone
    lst2 = requests.get(f"{TRADING}/api/v1/price-alerts", headers=hdr(uid), timeout=8)
    assert lst2.status_code == 200, lst2.text
    assert not any(x["id"] == alert_id for x in lst2.json()), "deleted alert still in list"

    # DELETE again -> 404 (idempotency / not-found path, rest.rs:1396)
    dele2 = requests.delete(f"{TRADING}/api/v1/price-alerts/{alert_id}", headers=hdr(uid), timeout=8)
    assert dele2.status_code == 404, f"second delete should 404: {dele2.status_code}"


def test_price_alert_invalid_condition_400(new_user):
    """create_price_alert:1314 rejects an unknown condition with 400."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.post(f"{TRADING}/api/v1/price-alerts",
                      json={"target_price": "1.0", "condition": "sideways"},
                      headers=hdr(uid), timeout=8)
    assert r.status_code == 400, f"expected 400 for bad condition: {r.status_code} {r.text}"


# =============================================================================
# Recurring-orders CRUD lifecycle — POST -> GET list -> GET {id}
#                                    -> pause -> resume -> DELETE
# =============================================================================

def test_recurring_order_crud_lifecycle(new_user):
    """POST /api/v1/orders/recurring (rest.rs create_recurring_order:1508) ->
    GET list (list_recurring_orders:1574) -> GET {id} (get_recurring_order:1597) ->
    POST {id}/pause (pause_recurring_order:1686) -> POST {id}/resume (resume:1699) ->
    DELETE {id} (delete_recurring_order:1627).

    CreateRecurringRequest:1410 — side, energy_amount:str, interval_type, optional
    min/max_price_per_kwh:str, interval_value, max_executions, name, description.
    RecurringOrderWire:1427 — decimals as strings; status is lowercase strum
    (active/paused, types.rs:245). pause/resume return {success:true}; status flips
    are asserted by re-reading GET {id}."""
    uid = new_user["user_id"] or pytest.skip("no user_id")

    # CREATE
    body = {"side": "buy", "energy_amount": "10.5", "max_price_per_kwh": "0.20",
            "interval_type": "daily", "interval_value": 2, "max_executions": 5,
            "name": "dca-e2e", "description": "e2e recurring"}
    create = requests.post(f"{TRADING}/api/v1/orders/recurring", json=body,
                           headers=hdr(uid), timeout=8)
    assert create.status_code == 200, f"create recurring: {create.status_code} {create.text}"
    o = create.json()
    rid = o["id"]
    assert o["user_id"] == str(uid)
    assert o["side"] == "buy"
    # Decimals are STRINGS; rust_decimal keeps trailing scale ("10.50000000"), so
    # assert numeric equality (build_recurring_response uses Decimal::to_string).
    assert isinstance(o["energy_amount"], str)
    assert Decimal(o["energy_amount"]) == Decimal("10.5")
    assert Decimal(o["max_price_per_kwh"]) == Decimal("0.20")
    assert o["min_price_per_kwh"] is None
    assert o["interval_type"] == "daily"
    assert o["interval_value"] == 2
    assert o["status"] == "active"                 # newly created -> active
    assert o["total_executions"] == 0
    assert o["max_executions"] == 5
    assert isinstance(o["next_execution_at"], str)

    # LIST — appears
    lst = requests.get(f"{TRADING}/api/v1/orders/recurring", headers=hdr(uid), timeout=8)
    assert lst.status_code == 200, lst.text
    assert any(x["id"] == rid for x in lst.json()), "created recurring order missing from list"

    # GET {id}
    one = requests.get(f"{TRADING}/api/v1/orders/recurring/{rid}", headers=hdr(uid), timeout=8)
    assert one.status_code == 200, one.text
    assert one.json()["id"] == rid
    assert one.json()["status"] == "active"

    # PAUSE -> status active -> paused
    pause = requests.post(f"{TRADING}/api/v1/orders/recurring/{rid}/pause",
                          headers=hdr(uid), timeout=8)
    assert pause.status_code == 200, f"pause: {pause.status_code} {pause.text}"
    assert pause.json().get("success") is True
    after_pause = requests.get(f"{TRADING}/api/v1/orders/recurring/{rid}", headers=hdr(uid), timeout=8)
    assert after_pause.status_code == 200, after_pause.text
    assert after_pause.json()["status"] == "paused", \
        f"status not paused after pause: {after_pause.json()['status']}"

    # RESUME -> paused -> active
    resume = requests.post(f"{TRADING}/api/v1/orders/recurring/{rid}/resume",
                           headers=hdr(uid), timeout=8)
    assert resume.status_code == 200, f"resume: {resume.status_code} {resume.text}"
    assert resume.json().get("success") is True
    after_resume = requests.get(f"{TRADING}/api/v1/orders/recurring/{rid}", headers=hdr(uid), timeout=8)
    assert after_resume.status_code == 200, after_resume.text
    assert after_resume.json()["status"] == "active", \
        f"status not active after resume: {after_resume.json()['status']}"

    # DELETE
    dele = requests.delete(f"{TRADING}/api/v1/orders/recurring/{rid}", headers=hdr(uid), timeout=8)
    assert dele.status_code == 200, f"delete recurring: {dele.status_code} {dele.text}"
    assert dele.json().get("success") is True

    # GET {id} after delete -> 404 (get_recurring_order:1620 None branch)
    gone = requests.get(f"{TRADING}/api/v1/orders/recurring/{rid}", headers=hdr(uid), timeout=8)
    assert gone.status_code == 404, f"deleted recurring still readable: {gone.status_code}"


def test_recurring_order_invalid_interval_400(new_user):
    """create_recurring_order:1519 rejects an unknown interval_type with 400."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    r = requests.post(f"{TRADING}/api/v1/orders/recurring",
                      json={"side": "buy", "energy_amount": "1", "interval_type": "yearly"},
                      headers=hdr(uid), timeout=8)
    assert r.status_code == 400, f"expected 400 for bad interval: {r.status_code} {r.text}"


# =============================================================================
# gRPC parity — TradingService ListOrders / GetOrder / CancelOrder
# (ConnectRPC over HTTP+JSON, camelCase fields; trading.proto:8,10,11 — IMPLEMENTED)
# =============================================================================

def _grpc_base():
    return os.getenv("TRADING_GRPC_HTTP",
                     "http://" + os.getenv("TRADING_GRPC", "localhost:8092"))


def _grpc(method, body, headers=None):
    url = f"{_grpc_base()}/trading.TradingService/{method}"
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    return requests.post(url, json=body, headers=h, timeout=8)


def test_grpc_list_orders_parity(new_user):
    """gRPC ListOrders (trading.proto:11, handlers.rs list_orders:216 — IMPLEMENTED,
    NOT a stub). ListOrdersRequest{userId}; ListOrdersResponse{orders:[OrderResponse]}.
    We place an order via REST then list it over gRPC and find it by id."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    placed = place_order(uid, "sell", 2, 777)  # high ask, stays open
    assert placed.status_code == 200, placed.text
    oid = placed.json()["id"]

    try:
        r = _grpc("ListOrders", {"userId": str(uid)}, hdr(uid))
    except requests.RequestException:
        pytest.skip("trading gRPC not reachable over plain HTTP")
    assert r.status_code == 200, f"gRPC ListOrders: {r.status_code} {r.text}"
    orders = r.json().get("orders", [])
    assert isinstance(orders, list)
    assert any(o.get("id") == oid for o in orders), \
        f"placed order {oid} not returned by gRPC ListOrders"


def test_grpc_get_order_parity(new_user):
    """gRPC GetOrder (trading.proto:10, handlers.rs get_order:144 — IMPLEMENTED).
    GetOrderRequest{orderId}; OrderResponse (proto:108) — ConnectRPC emits JSON in
    camelCase: id, userId, energyAmount(f64), pricePerKwh(f64), filledAmount(f64,
    elided when 0), side, status, createdAt, zoneId. side/status lowercased
    (handlers.rs:170-171)."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    placed = place_order(uid, "sell", 3, 666)
    assert placed.status_code == 200, placed.text
    oid = placed.json()["id"]

    try:
        r = _grpc("GetOrder", {"orderId": oid}, hdr(uid))
    except requests.RequestException:
        pytest.skip("trading gRPC not reachable over plain HTTP")
    assert r.status_code == 200, f"gRPC GetOrder: {r.status_code} {r.text}"
    o = r.json()
    assert o["id"] == oid
    assert o["userId"] == str(uid)
    # Proto OrderResponse: amounts are f64 (handlers.rs:167), camelCase on the wire.
    assert isinstance(o["energyAmount"], (int, float))
    assert isinstance(o["pricePerKwh"], (int, float))
    assert o["side"] == "sell"


def test_grpc_cancel_order_parity(new_user):
    """gRPC CancelOrder (trading.proto:8, handlers.rs cancel_order:178 — IMPLEMENTED).
    CancelOrderRequest{orderId,userId}; TradingResponse{success:bool,message,id?}.
    Cancels an order we just placed; success must be true."""
    uid = new_user["user_id"] or pytest.skip("no user_id")
    placed = place_order(uid, "sell", 1, 555)
    assert placed.status_code == 200, placed.text
    oid = placed.json()["id"]

    try:
        r = _grpc("CancelOrder", {"orderId": oid, "userId": str(uid)}, hdr(uid))
    except requests.RequestException:
        pytest.skip("trading gRPC not reachable over plain HTTP")
    assert r.status_code == 200, f"gRPC CancelOrder: {r.status_code} {r.text}"
    j = r.json()
    # buffa/ConnectRPC omits default-false bools; treat absent success as the
    # not-cancelled signal. A freshly-placed open order should cancel cleanly.
    assert j.get("success") is True, f"cancel did not succeed: {j}"
    assert j.get("id") == oid
