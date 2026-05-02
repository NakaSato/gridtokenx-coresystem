import base58
import json
import os
import sys
import time
from cryptography.hazmat.primitives.asymmetric import ed25519

def generate_keys(key_path="test_meter_keys.json"):
    private_key = ed25519.Ed25519PrivateKey.generate()
    public_key = private_key.public_key()
    
    private_bytes = private_key.private_bytes_raw()
    public_bytes = public_key.public_bytes_raw()
    
    keys = {
        "private_hex": private_bytes.hex(),
        "public_hex": public_bytes.hex(),
    }
    
    with open(key_path, "w") as f:
        json.dump(keys, f)
    
    print(f"Keys saved to {key_path}")
    print(f"Public Key Hex: {keys['public_hex']}")
    return keys

def sign_payload(meter_id, energy_generated, timestamp_ms, key_path="test_meter_keys.json"):
    if not os.path.exists(key_path):
        print(f"Error: {key_path} not found.")
        sys.exit(1)
        
    with open(key_path, "r") as f:
        keys = json.load(f)
        
    private_bytes = bytes.fromhex(keys["private_hex"])
    private_key = ed25519.Ed25519PrivateKey.from_private_bytes(private_bytes)
    
    # Canonical signing format: {meter_id}:{kwh:.6f}:{timestamp_ms}
    # Note: kwh is formatted to exactly 6 decimal places to match the bridge/simulator standard
    message = f"{meter_id}:{float(energy_generated):.6f}:{timestamp_ms}".encode()
    signature = private_key.sign(message)
    
    return base58.b58encode(signature).decode()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 sign_telemetry.py [gen|sign] ...")
        sys.exit(1)
        
    cmd = sys.argv[1]
    if cmd == "gen":
        generate_keys()
    elif cmd == "sign":
        if len(sys.argv) < 5:
            print("Usage: python3 sign_telemetry.py sign <meter_id> <energy_generated> <timestamp_ms>")
            sys.exit(1)
        meter_id = sys.argv[2]
        energy = sys.argv[3]
        ts = sys.argv[4]
        sig = sign_payload(meter_id, energy, ts)
        print(sig)
