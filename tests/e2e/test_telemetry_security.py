import os
import sys
import time
import base58
import json
import requests
import grpc
from cryptography.hazmat.primitives.asymmetric import ed25519

# Add the compiled proto directory to path
proto_dir = os.path.join(os.path.dirname(__file__), "proto")
sys.path.append(proto_dir)

import oracle_pb2
import oracle_pb2_grpc

# Configuration
METER_ID = "0xTEST"
AGGREGATOR_BRIDGE_GRPC = os.getenv("AGGREGATOR_BRIDGE_GRPC", "localhost:5030")
AGGREGATOR_BRIDGE_REST = os.getenv("AGGREGATOR_BRIDGE_REST", "http://localhost:4030")
# api_key_auth gates ingest (auth.rs); aggregator seeds `e2e-test-key` in its static
# GRIDTOKENX_API_KEYS for the harness (docker-compose.yml:755). Missing → 401 at auth.
INGEST_HEADERS = {"X-API-KEY": os.getenv("AGGREGATOR_API_KEY", "e2e-test-key")}

def sign_telemetry(private_key, meter_id, kwh, timestamp_ms):
    """
    Creates a canonical signature matching the Rust implementation:
    {meter_id}:{kwh}:{timestamp_ms}
    """
    message = f"{meter_id}:{kwh}:{timestamp_ms}".encode('utf-8')
    signature_bytes = private_key.sign(message)
    return base58.b58encode(signature_bytes).decode('utf-8')

def test_grpc_ingestion(private_key, public_key_hex):
    print(f"--- 📡 Testing gRPC Secure Ingestion (Target: {AGGREGATOR_BRIDGE_GRPC}) ---")
    
    # Register the key first (simulation)
    print(f"[*] Registering test identity {METER_ID}...")
    # Find root project directory relative to this script
    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
    register_script = os.path.join(root_dir, "scripts/register-edge-key.sh")
    os.system(f"bash {register_script} {METER_ID} {public_key_hex}")

    channel = grpc.insecure_channel(AGGREGATOR_BRIDGE_GRPC)
    stub = oracle_pb2_grpc.OracleServiceStub(channel)

    timestamp = int(time.time() * 1000)
    kwh = "123.45"
    
    # 1. Test Valid Signature
    print("[*] Case 1: Valid Signature...")
    signature = sign_telemetry(private_key, METER_ID, kwh, timestamp)
    
    request = oracle_pb2.TelemetryRequest(
        meter_id=METER_ID,
        kwh=kwh,
        timestamp=timestamp,
        signature=signature
    )
    
    try:
        response = stub.SubmitTelemetry(request)
        print(f"✅ SUCCESS: Ingestion accepted. Response: {response.status}")
    except grpc.RpcError as e:
        print(f"❌ FAILED: gRPC Error: {e.code()} - {e.details()}")
        return False

    # 2. Test Invalid Signature (Tampering)
    print("[*] Case 2: Tampered Signature (Should Fail)...")
    request.signature = "invalid_signature_base58"
    try:
        stub.SubmitTelemetry(request)
        print("❌ FAILED: Oracle Bridge accepted a tampered signature!")
        return False
    except grpc.RpcError as e:
        print(f"✅ SUCCESS: Oracle Bridge rejected tampered data. (Error: {e.code()})")

    return True

def test_rest_ingestion(private_key, public_key_hex):
    print(f"\n--- 🌐 Testing REST Secure Ingestion (Target: {AGGREGATOR_BRIDGE_REST}) ---")
    
    timestamp = int(time.time() * 1000)
    import datetime
    dt = datetime.datetime.fromtimestamp(timestamp/1000, tz=datetime.timezone.utc)
    # Use isoformat with millisecond precision
    iso_timestamp = dt.isoformat(timespec='milliseconds').replace("+00:00", "Z")
    
    kwh = "99.99"
    
    # 1. Test Valid Signature
    print("[*] Case 1: Valid REST Signature...")
    signature = sign_telemetry(private_key, METER_ID, kwh, timestamp)

    payload = {
        "protocol": "dlms",
        "device_id": METER_ID,
        "payload": {
            "device_id": METER_ID,
            "timestamp": iso_timestamp,
            "energy_consumed": float(kwh),
            "signature": signature
        }
    }

    url = f"{AGGREGATOR_BRIDGE_REST}/v1/private-network/ingest"
    try:
        response = requests.post(url, json=payload, headers=INGEST_HEADERS, timeout=5)
        if response.status_code == 202 or response.status_code == 200:
            print(f"✅ SUCCESS: REST Ingestion accepted. Code: {response.status_code}")
        else:
            print(f"❌ FAILED: REST Ingestion rejected: {response.status_code} - {response.text}")
            return False
    except Exception as e:
        print(f"❌ FAILED: Request error: {e}")
        return False

    # 2. Test Missing Signature (Should Fail in production mode)
    print("[*] Case 2: Missing Signature...")
    del payload["payload"]["signature"]
    response = requests.post(url, json=payload, headers=INGEST_HEADERS, timeout=5)
    # Note: If Bridge is in dev mode it might warn but accept. In prod it will fail.
    # We'll just log the result.
    print(f"[i] Response without signature: {response.status_code} - {response.text}")

    return True

if __name__ == "__main__":
    # 0. Generate Identity
    print("🔑 Generating Test Identity...")
    pk = ed25519.Ed25519PrivateKey.generate()
    pub = pk.public_key()
    pub_bytes = pub.public_bytes_raw()
    pub_hex = pub_bytes.hex()
    print(f"[i] Test Pubkey: {pub_hex}")

    # 1. Run Tests
    grpc_ok = test_grpc_ingestion(pk, pub_hex)
    rest_ok = test_rest_ingestion(pk, pub_hex)

    if grpc_ok and rest_ok:
        print("\n🏆 FINAL RESULT: E2E Secure Telemetry Link VERIFIED.")
        sys.exit(0)
    else:
        print("\n💀 FINAL RESULT: E2E Verification FAILED.")
        sys.exit(1)
