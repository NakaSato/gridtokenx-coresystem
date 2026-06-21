"""GridTokenX E2E — sign `chain.tx.*` NATS envelopes (scheme v1).

Mirrors `gridtokenx-blockchain-core/src/rpc/envelope_auth.rs` BYTE-FOR-BYTE. The
bridge enforces publisher signing when `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true`
(the dev compose default, docker-compose.yml:393): it verifies the leaf cert
chains to the dev CA, the SPIFFE URI SAN equals the envelope `service_identity`,
then the ECDSA P-256/SHA-256 signature over the canonical bytes.

Canonical encoding (see the Rust module — the two MUST agree or every signature
fails verification):
  - prefix:  DOMAIN_TAG + kind + 0x00
  - per field: name + 0x00 + u64_LE(len) + bytes  (length-prefixed, ordered)
  - the `auth` field itself is never part of the signed bytes
  - the transaction enters as its SHA-256 (`tx_sha256`), not raw

Signing key + cert come from the dev mTLS client material under
`infra/certs/clients/<name>.{crt,key}` (P-256, what `scripts/gen-certs.sh` emits).
Pick `<name>` so its SPIFFE SAN matches the envelope `service_identity` AND its
mapped ServiceRole satisfies the consumer's RBAC gate for that subject.
"""
import base64
import hashlib
import os
import struct

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

SCHEME_V1 = "ecdsa-p256-sha256-v1"
DOMAIN_TAG = b"gridtokenx-nats-envelope-v1\x00"

# tests/e2e/lib -> repo root (../../..) -> infra/certs/clients. Override via env.
CERTS_DIR = os.getenv(
    "E2E_CLIENT_CERTS_DIR",
    os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..", "..", "infra", "certs", "clients")
    ),
)


def _push_field(buf: bytearray, name: str, value: bytes) -> None:
    buf.extend(name.encode("utf-8"))
    buf.append(0)
    buf.extend(struct.pack("<Q", len(value)))
    buf.extend(value)


def _base(kind: str) -> bytearray:
    return bytearray(DOMAIN_TAG + kind.encode("utf-8") + b"\x00")


def _tx_sha256(serialized_tx) -> bytes:
    return hashlib.sha256(bytes(serialized_tx)).digest()


def canonical_submit(env: dict) -> bytes:
    buf = _base("submit")
    _push_field(buf, "correlation_id", env["correlation_id"].encode())
    _push_field(buf, "idempotency_key", env.get("idempotency_key", "").encode())
    _push_field(buf, "reply_subject", env["reply_subject"].encode())
    _push_field(buf, "key_id", env["key_id"].encode())
    _push_field(buf, "service_identity", env["service_identity"].encode())
    _push_field(buf, "created_at_ms", struct.pack("<Q", env["created_at_ms"]))
    _push_field(buf, "skip_preflight", bytes([1 if env["skip_preflight"] else 0]))
    _push_field(buf, "retry_count", struct.pack("<I", env["retry_count"]))
    _push_field(buf, "tx_sha256", _tx_sha256(env["serialized_tx"]))
    return bytes(buf)


def canonical_simulate(env: dict) -> bytes:
    buf = _base("simulate")
    _push_field(buf, "correlation_id", env["correlation_id"].encode())
    _push_field(buf, "reply_subject", env["reply_subject"].encode())
    _push_field(buf, "key_id", env["key_id"].encode())
    _push_field(buf, "service_identity", env["service_identity"].encode())
    _push_field(buf, "created_at_ms", struct.pack("<Q", env["created_at_ms"]))
    _push_field(buf, "tx_sha256", _tx_sha256(env["serialized_tx"]))
    return bytes(buf)


def canonical_status(env: dict) -> bytes:
    buf = _base("status")
    _push_field(buf, "correlation_id", env["correlation_id"].encode())
    _push_field(buf, "reply_subject", env["reply_subject"].encode())
    _push_field(buf, "signature", env["signature"].encode())
    _push_field(buf, "service_identity", env["service_identity"].encode())
    _push_field(buf, "created_at_ms", struct.pack("<Q", env["created_at_ms"]))
    return bytes(buf)


_CANONICAL = {
    "submit": canonical_submit,
    "simulate": canonical_simulate,
    "status": canonical_status,
}


def _cert_pem(name: str) -> str:
    with open(os.path.join(CERTS_DIR, f"{name}.crt"), "r", encoding="utf-8") as f:
        return f.read()


def _signing_key(name: str):
    with open(os.path.join(CERTS_DIR, f"{name}.key"), "rb") as f:
        return serialization.load_pem_private_key(f.read(), password=None)


def sign_for(kind: str, env: dict, cert_name: str) -> dict:
    """Return the EnvelopeAuth dict for `env` (subject `kind`), signed with the
    dev client cert `cert_name`. `cert_name`'s SPIFFE SAN must equal
    env['service_identity'] or the bridge rejects the cert↔identity binding."""
    canonical = _CANONICAL[kind](env)
    key = _signing_key(cert_name)
    sig_der = key.sign(canonical, ec.ECDSA(hashes.SHA256()))  # DER-encoded
    return {
        "scheme": SCHEME_V1,
        "cert_pem": _cert_pem(cert_name),
        "signature": base64.b64encode(sig_der).decode("ascii"),
    }


def material_available(cert_name: str) -> bool:
    """True if both cert + key exist for `cert_name` (lets tests skip cleanly when
    dev cert material isn't present, e.g. certs not generated)."""
    return os.path.isfile(os.path.join(CERTS_DIR, f"{cert_name}.crt")) and os.path.isfile(
        os.path.join(CERTS_DIR, f"{cert_name}.key")
    )
