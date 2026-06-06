"""GridTokenX E2E — Ed25519 device identity + telemetry signing.

Canonical message matches Rust Oracle Bridge: f"{meter_id}:{kwh}:{timestamp_ms}".
Reuses the scheme proven in test_telemetry_security.py.
"""
import base58
from cryptography.hazmat.primitives.asymmetric import ed25519


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
