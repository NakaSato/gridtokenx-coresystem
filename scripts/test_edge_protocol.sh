#!/bin/bash
# Edge Protocol Integration Test Orchestrator

# Kill background processes on exit
trap "kill 0" EXIT

echo "[*] Starting Edge Gateway..."
cd gridtokenx-edge-gateway
cargo run &
GATEWAY_PID=$!

# Wait for listeners to start
sleep 5

echo "[*] Launching Mock Meters..."
# Grid Meter (HPLC)
python3 scripts/mock_meter.py --transport hplc --address 0001 --port 9000 --mode robo &
# Solar Meter (RF Mesh)
python3 scripts/mock_meter.py --transport rf --address 0011 --port 9001 --mode bpsk &
# EVSE Meter (RF Mesh)
python3 scripts/mock_meter.py --transport rf --address 0012 --port 9002 --mode qpsk &

echo "[*] Simulation running. Monitoring logs for 120 seconds..."
sleep 120

echo "[*] Test complete."
