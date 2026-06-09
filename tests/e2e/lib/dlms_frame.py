"""GridTokenX E2E — Secure DLMS-lite v4 binary frame builder.

Byte-for-byte Python mirror of the Rust codec the Aggregator Bridge decodes with
(`gridtokenx-aggregator-bridge/crates/aggregator-stacks/src/binary_decoder.rs`,
builder `frame_from_tlv` lines 225-259, parser `parse` lines 87-168). Used by the
encrypted-DLMS gRPC e2e to feed the bridge's `BulkRawIngest` / `decode_secure_frame`
path — the only client that produces these frames (the simulator stays REST-plaintext).

Frame layout (server is ground truth — if a built frame decodes server-side, bytes match):

    [ver=0x04 1B][total_len 1B][manuf 3B][LDN 8B null-pad/trunc][ts_sec 8B BE]
      [block][crc32 4B BE]

    block  = AES-256-GCM(tlv)  (ciphertext ++ 16B tag)   |  plaintext tlv (key=None)
    nonce  = manuf(3B) ++ ts(8B BE) ++ ver(1B)  = 12B     (binary_decoder.rs:118-122)
    total_len byte = (len_before_crc - 2) + 4             (binary_decoder.rs:254)
    crc32  = zlib.crc32(payload[..before crc])  big-endian (binary_decoder.rs:255-257)

TLV (tag 1B, len 1B, value): 1=import_wh u64/8B, 2=export_wh u64/8B,
3=voltage_cv u32/4B, 4=current_ma u32/4B, 5=battery_soc_bps u32/4B.
"""
from __future__ import annotations

import struct
import zlib
from typing import Optional

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PROTOCOL_VERSION_V4 = 0x04
DEFAULT_MANUF = b"INC"          # 3 bytes; must be the bytes the nonce is derived from
DEFAULT_TS_SEC = 1700000000      # fixed, deterministic (matches the Rust reference test)


def build_tlv(
    *,
    import_wh: Optional[int] = None,
    export_wh: Optional[int] = None,
    voltage_cv: Optional[int] = None,
    current_ma: Optional[int] = None,
    battery_soc_bps: Optional[int] = None,
) -> bytes:
    """Encode the measurement TLV block the bridge's parser extracts (tags 1-5)."""
    tlv = bytearray()
    if import_wh is not None:
        tlv += bytes([1, 8]) + struct.pack(">Q", import_wh)
    if export_wh is not None:
        tlv += bytes([2, 8]) + struct.pack(">Q", export_wh)
    if voltage_cv is not None:
        tlv += bytes([3, 4]) + struct.pack(">I", voltage_cv)
    if current_ma is not None:
        tlv += bytes([4, 4]) + struct.pack(">I", current_ma)
    if battery_soc_bps is not None:
        tlv += bytes([5, 4]) + struct.pack(">I", battery_soc_bps)
    return bytes(tlv)


def frame_from_tlv(
    ldn: str,
    tlv: bytes,
    enc_key: Optional[bytes] = None,
    *,
    manuf: bytes = DEFAULT_MANUF,
    ts_sec: int = DEFAULT_TS_SEC,
) -> bytes:
    """Assemble a full secure-v4 frame from a caller-built TLV block.

    `enc_key` is the 32-byte AES-256 key. When given, the TLV block is AES-256-GCM
    encrypted (nonce = manuf++ts++ver) exactly as `parse` expects; when None, the
    block is plaintext (dev/legacy path, decoded only under ALLOW_PLAINTEXT_DLMS).
    """
    if len(manuf) != 3:
        raise ValueError("manuf must be exactly 3 bytes")
    ts_bytes = struct.pack(">Q", ts_sec)

    if enc_key is not None:
        if len(enc_key) != 32:
            raise ValueError("enc_key must be 32 bytes (AES-256)")
        nonce = manuf + ts_bytes + bytes([PROTOCOL_VERSION_V4])  # 3 + 8 + 1 = 12
        # AESGCM.encrypt appends the 16-byte tag — matches Rust aes-gcm output.
        block = AESGCM(enc_key).encrypt(nonce, tlv, None)
    else:
        block = tlv

    ldn_bytes = ldn.encode()[:8].ljust(8, b"\0")

    payload = bytearray()
    payload.append(PROTOCOL_VERSION_V4)
    payload.append(0)  # total-length placeholder
    payload += manuf
    payload += ldn_bytes
    payload += ts_bytes
    payload += block

    payload[1] = (len(payload) - 2 + 4) & 0xFF  # total_len: trailer-relative + CRC
    crc = zlib.crc32(bytes(payload)) & 0xFFFFFFFF
    payload += struct.pack(">I", crc)
    return bytes(payload)


def build_v4_frame(
    ldn: str,
    enc_key: Optional[bytes] = None,
    *,
    import_wh: int = 5000,
    export_wh: Optional[int] = None,
    **tlv_extra,
) -> bytes:
    """Convenience: a v4 frame carrying import (+ optional export / extras) energy."""
    tlv = build_tlv(import_wh=import_wh, export_wh=export_wh, **tlv_extra)
    return frame_from_tlv(ldn, tlv, enc_key)


def bulk_payload(entries: list[tuple[bytes, bytes]]) -> bytes:
    """Pack the `BulkRawRequest.payload` wire: repeat(len:1B ++ frame ++ sig:64B).

    `entries` is a list of (frame_bytes, ed25519_sig_64). Mirrors the bridge's
    unpack loop (grpc/service.rs:158-169): the bridge verifies each sig against the
    *frame bytes*, so the sig must be over `frame`, raw 64 bytes.
    """
    out = bytearray()
    for frame, sig in entries:
        if len(frame) > 255:
            raise ValueError("frame too long for 1-byte length prefix")
        if len(sig) != 64:
            raise ValueError("ed25519 signature must be 64 bytes")
        out.append(len(frame))
        out += frame
        out += sig
    return bytes(out)
