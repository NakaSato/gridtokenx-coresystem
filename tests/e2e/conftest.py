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

IAM_URL = os.getenv("IAM_URL", "http://localhost:4010")
E2E_RUN_ID = os.getenv("E2E_RUN_ID", str(int(time.time())))
E2E_PASSWORD = os.getenv("E2E_PASSWORD", "GRX-Secure-P@ss-2026-E2E")


@pytest.fixture(scope="session")
def endpoints():
    return {
        "iam": IAM_URL,
        "iam_grpc": os.getenv("IAM_GRPC", "localhost:5010"),
        "trading": os.getenv("TRADING_URL", "http://localhost:8093"),
        "trading_grpc": os.getenv("TRADING_GRPC", "localhost:8092"),
        "oracle_rest": os.getenv("ORACLE_BRIDGE_REST", "http://localhost:4030"),
        "oracle_grpc": os.getenv("ORACLE_BRIDGE_GRPC", "localhost:5030"),
        "chain_grpc": os.getenv("CHAIN_BRIDGE_GRPC", "localhost:5040"),
        "noti_grpc": os.getenv("NOTI_GRPC", "localhost:5050"),
    }


@pytest.fixture
def new_user():
    """Register + verify a fresh user. Returns dict(jwt, username, email, wallet)."""
    username = f"e2e_{E2E_RUN_ID}_{int(time.time()*1000)%100000}"
    email = f"{username}@grx.test"
    r = requests.post(f"{IAM_URL}/api/v1/auth/register",
                      json={"username": username, "email": email, "password": E2E_PASSWORD}, timeout=10)
    assert r.status_code in (200, 201), f"register failed: {r.status_code} {r.text}"
    v = requests.get(f"{IAM_URL}/api/v1/auth/verify",
                     params={"token": f"verify_{email}"}, timeout=10)
    assert v.status_code == 200, f"verify failed: {v.status_code} {v.text}"
    body = v.json()
    jwt = body.get("auth", {}).get("access_token")
    return {
        "jwt": jwt,
        "user_id": _jwt_sub(jwt),
        "username": username,
        "email": email,
        "wallet": body.get("wallet_address"),
    }


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
