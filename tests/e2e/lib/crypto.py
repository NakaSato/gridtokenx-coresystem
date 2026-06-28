"""GridTokenX E2E — Ed25519 device identity + telemetry signing.

Canonical message matches Rust Oracle Bridge: f"{meter_id}:{kwh}:{timestamp_ms}".
"""
import base64
import hashlib
import hmac
import json
import time

import base58
from cryptography.hazmat.primitives.asymmetric import ed25519


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def mint_hs256_jwt(secret: str, sub: str = "e2e-test", ttl_secs: int = 300,
                   **extra_claims) -> str:
    """Mint a minimal HS256 JWT with stdlib only (no PyJWT in the e2e venv).

    Noti's gRPC auth gate (`crates/noti-api/src/grpc.rs`) requires
    `Authorization: Bearer <token>` where the token is HS256-signed with the
    service's `JWT_SECRET` and decoded with jsonwebtoken's `Validation::default()`
    — which deserializes `sub` and REQUIRES a non-expired `exp`. So the payload
    carries both.

    `ttl_secs` may be negative to mint an already-expired token (exp in the past).
    `extra_claims` are merged into the payload — e.g. APISIX's jwt-auth maps a token
    to its consumer via the `key` claim, so pass `key="gridtokenx-iam-service"` to
    target the gateway consumer.
    """
    header = _b64url(
        json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode()
    )
    claims = {"sub": sub, "exp": int(time.time()) + ttl_secs}
    claims.update(extra_claims)
    payload = _b64url(
        json.dumps(claims, separators=(",", ":")).encode()
    )
    signing_input = f"{header}.{payload}".encode("ascii")
    sig = hmac.new(secret.encode("utf-8"), signing_input, hashlib.sha256).digest()
    return f"{header}.{payload}.{_b64url(sig)}"


def new_identity():
    """Return (private_key, public_key_hex)."""
    pk = ed25519.Ed25519PrivateKey.generate()
    pub_hex = pk.public_key().public_bytes_raw().hex()
    return pk, pub_hex


def rust_f64_str(value) -> str:
    """Format a number the way Rust's f64::to_string() does.

    The Oracle Bridge derives `kwh` for its canonical signing string from the
    energy_* JSON value as an f64, then `.to_string()`s it (handlers.rs). So the
    client MUST sign the same form. The key divergence from Python's str(float):
    Rust drops the fraction for integer-valued floats (200.00 -> "200", not
    "200.0"); for non-integers both use the shortest round-trip repr, which agree.
    """
    f = float(value)
    if f == int(f):
        return str(int(f))
    return repr(f)


def sign_telemetry(private_key, meter_id: str, kwh, timestamp_ms: int) -> str:
    """Base58 signature over canonical {meter_id}:{kwh}:{timestamp_ms}.

    kwh is canonicalized to Rust f64::to_string() form so the signed message
    matches what the Oracle Bridge reconstructs from the telemetry float."""
    message = f"{meter_id}:{rust_f64_str(kwh)}:{timestamp_ms}".encode("utf-8")
    return base58.b58encode(private_key.sign(message)).decode("utf-8")


def sign_raw(private_key, data: bytes) -> bytes:
    """Raw 64-byte Ed25519 signature over `data`.

    The bridge's bulk path (grpc/service.rs BulkRawIngest) verifies each frame's
    signature as raw 64 bytes against the frame bytes —
    `verify_telemetry_signature_batch` calls `Signature::from_bytes(&[u8; 64])`,
    NOT the base58 decode the REST/single-Ingest path uses. So bulk frames must be
    signed with this, not `sign_telemetry`."""
    return private_key.sign(data)


def keypair_base58_pubkey(private_key) -> str:
    """Base58-encoded Ed25519 public key (Solana pubkey form) for an Ed25519
    private key. Use to set trading's AGGREGATOR_BRIDGE_PUBLIC_KEY to a key the test
    holds, so the test can sign generation-mint requests trading will accept."""
    return base58.b58encode(private_key.public_key().public_bytes_raw()).decode("utf-8")


def sign_generation_mint(private_key, user_id: str, meter_serial: str, kwh_str: str,
                         start_time: int, end_time: int) -> str:
    """Base58 Ed25519 signature for the trading-service generation-mint REST
    endpoint. Canonical message matches trading rest.rs:841 exactly:
        f"{user_id}:{meter_serial}:{energy_generated_kwh}:{start_time}:{end_time}"

    `kwh_str` MUST be the same string sent in the request body and must match
    Rust rust_decimal::Decimal::Display (no trailing zeros, e.g. "50" or "100.5"),
    else trading reconstructs a different message and the signature fails to verify.
    """
    message = f"{user_id}:{meter_serial}:{kwh_str}:{start_time}:{end_time}".encode("utf-8")
    return base58.b58encode(private_key.sign(message)).decode("utf-8")
