#!/bin/bash
# Start GridTokenX Services for Stress Testing
export PATH="$HOME/.cargo/bin:$PATH"

PROJECT_ROOT=$(pwd)
mkdir -p "$PROJECT_ROOT/scripts/logs"

# Environment Variables
export IAM_DATABASE_URL="postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx_iam"
export TRADING_DATABASE_URL="postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx_trading"
export NOTI_DATABASE_URL="postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx_noti"
export REDIS_URL="redis://localhost:7010"
export SOLANA_RPC_URL="http://localhost:8899"
export SOLANA_WS_URL="ws://localhost:8900"
export KAFKA_BOOTSTRAP_SERVERS="localhost:29001"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4317"
export OTEL_ENABLED="true"
export ENCRYPTION_SECRET="supersecretencryptionkey"
export GRIDTOKENX_API_KEYS="engineering-department-api-key-2025"

echo "🚀 Starting GridTokenX Microservices..."

# 1. Chain Bridge
echo "🔗 Starting Chain Bridge..."
cd "$PROJECT_ROOT/gridtokenx-chain-bridge" && ./target/debug/gridtokenx-chain-bridge > "$PROJECT_ROOT/scripts/logs/chain-bridge.log" 2>&1 &
sleep 2

# 2. IAM Service
echo "👤 Starting IAM Service..."
cd "$PROJECT_ROOT/gridtokenx-iam-service" && DATABASE_URL=$IAM_DATABASE_URL ./target/debug/gridtokenx-iam-service > "$PROJECT_ROOT/scripts/logs/iam.log" 2>&1 &
sleep 2

# 3. Trading Service
echo "📈 Starting Trading Service..."
cd "$PROJECT_ROOT/gridtokenx-trading-service" && DATABASE_URL=$TRADING_DATABASE_URL ./target/debug/trading-service > "$PROJECT_ROOT/scripts/logs/trading.log" 2>&1 &
sleep 2

# 4. Oracle Bridge
echo "🔮 Starting Oracle Bridge..."
cd "$PROJECT_ROOT/gridtokenx-oracle-bridge" && DATABASE_URL="postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx" ./target/debug/oracle-service > "$PROJECT_ROOT/scripts/logs/oracle-bridge.log" 2>&1 &
sleep 2

# 5. Noti Service
echo "🔔 Starting Noti Service..."
cd "$PROJECT_ROOT/gridtokenx-noti-service" && DATABASE_URL=$NOTI_DATABASE_URL ./target/debug/noti-server > "$PROJECT_ROOT/scripts/logs/noti.log" 2>&1 &
sleep 2

# 6. Simulator API
echo "📊 Starting Smart Meter Simulator..."
cd "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/backend" && PORT=12010 uv run start > "$PROJECT_ROOT/scripts/logs/simulator-api.log" 2>&1 &

echo "✅ All services started in background. Check logs in scripts/logs/"
