#!/usr/bin/env python3
"""
GridTokenX - Single Smart Meter Telemetry Sender

Submits simulated telemetry readings to the Oracle Bridge via gRPC.
Automatically generates Ed25519 keys, registers them in Redis, and signs the payload.
"""

import argparse
import os
import random
import subprocess
import sys
import time

import base58
import grpc
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519

# Add the compiled proto directory to path
root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
proto_dir = os.path.join(root_dir, "tests/e2e/proto")
sys.path.append(proto_dir)

try:
    import oracle_pb2
    import oracle_pb2_grpc
except ImportError as e:
    print(f"Error importing protos: {e}")
    print(
        "Ensure you run this with the virtualenv: gridtokenx-smartmeter-simulator/backend/.venv/bin/python"
    )
    sys.exit(1)


def sign_telemetry(private_key, meter_id, kwh, timestamp_ms):
    """Canonical signature: {meter_id}:{kwh}:{timestamp_ms}"""
    message = f"{meter_id}:{kwh}:{timestamp_ms}".encode("utf-8")
    signature_bytes = private_key.sign(message)
    return base58.b58encode(signature_bytes).decode("utf-8")


def get_or_create_keypair(meter_id):
    """Gets existing keypair for meter_id or generates a new one."""
    keys_dir = os.path.join(os.path.dirname(__file__), "keys")
    os.makedirs(keys_dir, exist_ok=True)

    priv_path = os.path.join(keys_dir, f"{meter_id}_private.pem")

    if os.path.exists(priv_path):
        with open(priv_path, "rb") as f:
            private_key = serialization.load_pem_private_key(f.read(), password=None)
            print(f"[*] Loaded existing key for {meter_id}")
    else:
        private_key = ed25519.Ed25519PrivateKey.generate()
        pem = private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        with open(priv_path, "wb") as f:
            f.write(pem)
        print(f"[*] Generated new key for {meter_id}")

    public_key = private_key.public_key()
    pub_hex = public_key.public_bytes_raw().hex()

    return private_key, pub_hex


def register_pubkey(meter_id, pub_hex):
    """Registers device public key in Redis so Oracle Bridge can verify telemetry signatures.

    Key format: gridtokenx:devices:<meter_id>:pubkey = <pubkey_hex>
    Tries redis-cli locally first, falls back to docker exec.
    """
    redis_host = os.environ.get("REDIS_HOST", "localhost")
    redis_port = os.environ.get("REDIS_PORT", "7010")
    redis_key = f"gridtokenx:devices:{meter_id}:pubkey"

    # Try local redis-cli first
    result = subprocess.run(
        ["redis-cli", "-h", redis_host, "-p", redis_port, "SET", redis_key, pub_hex],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0 and "OK" in result.stdout:
        print(
            f"[*] Key registered in Redis ({redis_host}:{redis_port}): {pub_hex[:16]}..."
        )
        return

    # Fall back to docker exec
    result = subprocess.run(
        ["docker", "exec", "gridtokenx-redis", "redis-cli", "SET", redis_key, pub_hex],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0 and "OK" in result.stdout:
        print(f"[*] Key registered in Redis (docker): {pub_hex[:16]}...")
        return

    print(f"❌ Failed to register key in Redis.")
    print(f"   Local redis-cli: {result.stderr.strip()}")
    print(
        f"   Ensure Redis is running at {redis_host}:{redis_port} or gridtokenx-redis container is up."
    )
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Send smartmeter data to Oracle Bridge"
    )
    parser.add_argument("--meter-id", required=True, help="Smart Meter ID / Serial")
    parser.add_argument(
        "--count", type=int, default=1, help="Number of readings to send"
    )
    parser.add_argument(
        "--grpc-port", type=int, default=50051, help="Oracle Bridge gRPC Port"
    )
    args = parser.parse_args()

    # 1. Identity & Registration
    private_key, pub_hex = get_or_create_keypair(args.meter_id)
    register_pubkey(args.meter_id, pub_hex)

    # 2. Connect to Oracle Bridge
    grpc_target = f"localhost:{args.grpc_port}"
    print(f"[*] Connecting to Oracle Bridge at {grpc_target}...")
    channel = grpc.insecure_channel(grpc_target)
    stub = oracle_pb2_grpc.OracleServiceStub(channel)

    # 3. Send Readings
    base_kwh = random.uniform(5.0, 15.0)

    for i in range(args.count):
        # Simulate slight variations in readings
        kwh = f"{base_kwh + random.uniform(-0.5, 2.0):.6f}"
        timestamp = int(time.time() * 1000)

        signature = sign_telemetry(private_key, args.meter_id, kwh, timestamp)

        request = oracle_pb2.TelemetryRequest(
            meter_id=args.meter_id, kwh=kwh, timestamp=timestamp, signature=signature
        )

        print(f"[{i + 1}/{args.count}] Sending: {kwh} kWh at {timestamp}")
        try:
            response = stub.SubmitTelemetry(request)
            print(
                f"   ✅ Accepted! Receipt: {response.receipt_id} Status: {response.status}"
            )
        except grpc.RpcError as e:
            print(f"   ❌ Failed: {e.code()} - {e.details()}")

        if i < args.count - 1:
            time.sleep(1)


if __name__ == "__main__":
    main()
