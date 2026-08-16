"""GridTokenX E2E — shared pytest fixtures.

Endpoints come from env (see env.sh). JWT factory hits IAM REST so Python suites
(gRPC/crypto) can authenticate without duplicating the bash flow.
"""
import base64
import json
import os
import sys
import time

import pytest
import requests

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "proto"))

# Aggregator Bridge ingest key. Auth is validated via IAM now (aggregator_api::auth), so the
# legacy static `e2e-test-key` is rejected (401). Mirror env.sh's canonical default so direct
# `pytest` runs (not via run.sh) still authenticate. Suites read os.getenv("AGGREGATOR_API_KEY").
os.environ.setdefault("AGGREGATOR_API_KEY", "engineering-department-api-key-2025")

# Aggregator Bridge gRPC ingest (BulkRawIngest) lands on host :50051 — docker-compose
# pins GRPC_PORT=50051 (compose:655,660); the container default 5030 is not published.
# Mirror env.sh so direct `pytest` runs (suites read os.getenv with a stale 5030 default)
# target the right port without an explicit override.
os.environ.setdefault("AGGREGATOR_BRIDGE_GRPC", "localhost:50051")

def _normalize_aggregator_scheme():
    """Point AGGREGATOR_BRIDGE_REST at TLS when the bridge is serving TLS.

    `env.sh:15` defaults it to `http://localhost:4030`, but docker-compose gives
    the bridge `IOT_GATEWAY_TLS_CERT`/`_KEY` by default, so under `just orb-up`
    the IoT gateway is **HTTPS**. Every suite's reachability probe therefore threw
    and the suites skipped — 20_oracle's 8 cases and 90_golden_path's bridge legs
    reported green while asserting nothing, which is indistinguishable from having
    no cases at all (the failure `tests/e2e/run.sh` already calls out for suites
    with no entry point).

    Auto-correct only when the configured plaintext URL is genuinely dead AND the
    TLS one answers, so an explicit override is never second-guessed and a
    plaintext bridge (bare-metal `start.sh`) is left alone.
    """
    url = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
    if not url.startswith("http://"):
        return

    try:
        requests.get(f"{url}/health", timeout=3)
        return  # plaintext works — nothing to correct
    except requests.exceptions.RequestException:
        pass

    https_url = "https://" + url[len("http://") :]
    ca = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "infra", "certs", "ca.crt",
    )
    probe = {"timeout": 3}
    if os.path.isfile(ca):
        probe["verify"] = ca
    try:
        requests.get(f"{https_url}/health", **probe)
    except requests.exceptions.RequestException:
        return  # neither answers — leave it, suites skip with their own reason

    os.environ["AGGREGATOR_BRIDGE_REST"] = https_url
    # Let suites keep calling bare `requests.get(...)` without threading `verify=`
    # through every call site. Safe here because every e2e endpoint is a localhost
    # dev service issued by this same dev CA; setdefault so an explicit bundle wins.
    if os.path.isfile(ca):
        os.environ.setdefault("REQUESTS_CA_BUNDLE", ca)


_normalize_aggregator_scheme()

IAM_URL = os.getenv("IAM_URL", "http://localhost:4010")
E2E_RUN_ID = os.getenv("E2E_RUN_ID", str(int(time.time())))
E2E_PASSWORD = os.getenv("E2E_PASSWORD", "GRX-Secure-P@ss-2026-E2E")
GATEWAY_SECRET = os.getenv("GATEWAY_SECRET", "gridtokenx-gateway-secret-2025")


@pytest.fixture(scope="session")
def endpoints():
    return {
        "iam": IAM_URL,
        "iam_grpc": os.getenv("IAM_GRPC", "localhost:5010"),
        "trading": os.getenv("TRADING_URL", "http://localhost:8093"),
        "trading_grpc": os.getenv("TRADING_GRPC", "localhost:8092"),
        "oracle_rest": os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030"),
        "oracle_grpc": os.getenv("AGGREGATOR_BRIDGE_GRPC", "localhost:5030"),
        "chain_grpc": os.getenv("CHAIN_BRIDGE_GRPC", "localhost:5040"),
        "noti_grpc": os.getenv("NOTI_GRPC", "localhost:5050"),
    }


def _reset_register_rate_limit():
    """Clear IAM's per-IP register rate-limit counter in Redis.

    IAM throttles /register to 5/hour per IP (rate_limit.rs:22), keyed in Redis as
    `iam:rate_limit:/register:{ip}` (keys.rs:41). A full e2e run provisions far more
    than 5 users, so without this reset the suite 429s partway through. Flushing the
    counter before each register keeps the suite repeatable. Best-effort: if Redis is
    unreachable we silently continue (the register may then 429, surfaced by the caller).
    """
    try:
        import redis
        r = redis.from_url(os.getenv("REDIS_URL", "redis://localhost:7010"), socket_timeout=2)
        keys = list(r.scan_iter(match="iam:rate_limit:/register:*"))
        if keys:
            r.delete(*keys)
    except Exception:
        pass


def _register_and_verify():
    """Register + verify a fresh user. Returns dict(jwt, username, email, wallet)."""
    # Salt the username with a per-call counter so two users provisioned in the
    # same millisecond (e.g. a cross-party trade test) never collide.
    _register_and_verify.n += 1
    username = f"e2e_{E2E_RUN_ID}_{int(time.time()*1000)%100000}_{_register_and_verify.n}"
    email = f"{username}@grx.test"
    _reset_register_rate_limit()
    r = requests.post(f"{IAM_URL}/api/v1/auth/register",
                      json={"username": username, "email": email, "password": E2E_PASSWORD}, timeout=15)
    assert r.status_code in (200, 201), f"register failed: {r.status_code} {r.text}"
    # verify runs the SYNCHRONOUS on-chain PDA registration (chain-bridge → NATS →
    # validator); measured ~14s under load, so the read timeout must clear that.
    v = requests.get(f"{IAM_URL}/api/v1/auth/verify",
                     params={"token": f"verify_{email}"},
                     timeout=float(os.getenv("IAM_VERIFY_TIMEOUT", "45")))
    assert v.status_code == 200, f"verify failed: {v.status_code} {v.text}"
    body = v.json()
    jwt = body.get("auth", {}).get("access_token")
    # Since iam `8b84ccd` verify no longer provisions a custodial wallet — the user
    # links their own primary wallet afterwards. Mirror that flow: generate a fresh
    # keypair and link it as primary so downstream suites (onboard, settlement,
    # golden path) have a wallet to work with.
    wallet = body.get("wallet_address")
    if not wallet:
        from solders.keypair import Keypair
        wallet = str(Keypair().pubkey())
        lw = requests.post(
            f"{IAM_URL}/api/v1/me/wallets",
            json={"wallet_address": wallet, "label": "E2E Primary", "is_primary": True},
            headers={
                "Authorization": f"Bearer {jwt}",
                "x-gridtokenx-role": "api-gateway",
                "x-gridtokenx-gateway-secret": GATEWAY_SECRET,
            },
            timeout=15,
        )
        assert lw.status_code in (200, 201), f"link primary wallet failed: {lw.status_code} {lw.text}"
    return {
        "jwt": jwt,
        "user_id": _jwt_sub(jwt),
        "username": username,
        "email": email,
        "wallet": wallet,
    }


_register_and_verify.n = 0


@pytest.fixture
def new_user():
    """Register + verify a fresh user. Returns dict(jwt, username, email, wallet)."""
    return _register_and_verify()


@pytest.fixture
def make_user():
    """Factory: call to provision an additional distinct verified user.

    Use when a test needs two separate identities (e.g. a cross-party trade
    where buyer and seller must differ, else the engine's self-trade guard
    blocks the match)."""
    return _register_and_verify


def _jwt_sub(jwt: str):
    """Extract `sub` (user id) from a JWT without verifying the signature."""
    if not jwt or jwt.count(".") != 2:
        return None
    payload = jwt.split(".")[1]
    payload += "=" * (-len(payload) % 4)  # pad base64url
    try:
        claims = json.loads(base64.urlsafe_b64decode(payload))
        return claims.get("sub") or claims.get("user_id")
    except Exception:
        return None
