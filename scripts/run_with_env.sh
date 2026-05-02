#!/bin/bash
# Port scheme: docs/architecture/PORT_NUMBERING_DESIGN.md
export DATABASE_URL="postgres://gridtokenx_user:gridtokenx_password@127.0.0.1:7001/gridtokenx"
export REDIS_URL="redis://127.0.0.1:7010"
export SOLANA_RPC_URL="http://127.0.0.1:8001"
export SOLANA_WS_URL="ws://127.0.0.1:8002"
export IAM_SERVICE_URL="http://127.0.0.1:4010"
export IAM_REST_URL="http://127.0.0.1:4010"
export IAM_GRPC_URL="http://127.0.0.1:5010"
export API_GATEWAY_URL="http://127.0.0.1:4000"
export TRADING_SERVICE_URL="http://127.0.0.1:4020"
export TRADING_GRPC_URL="http://127.0.0.1:5020"
export ORACLE_HTTP_URL="http://127.0.0.1:4030"
export ORACLE_GRPC_URL="http://127.0.0.1:5030"
export CHAIN_BRIDGE_GRPC_URL="http://127.0.0.1:5040"
export JWT_SECRET="dev-jwt-secret-key-minimum-32-characters-long-for-development-2025"
export ENCRYPTION_SECRET="dev-encryption-secret-key-32-chars-minimum-for-wallet-encryption"
export API_KEY_SECRET="test-api-key-secret-for-development-and-testing"
export ENVIRONMENT="development"
export LOG_LEVEL="info"
export APIGATEWAY_PORT=4000
export MAX_CONNECTIONS=100
export REDIS_POOL_SIZE=20
export AUDIT_LOG_ENABLED=true
export ENGINEERING_API_KEY="engineering-department-api-key-2025"
export ENERGY_TOKEN_MINT="2Zx6bpmjFAwuagwQqcqWhHiMKeCPPtCQLF8kfGMDCtJj"

echo "Starting $1..."
exec "$@"
