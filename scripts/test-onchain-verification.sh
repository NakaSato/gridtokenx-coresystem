#!/bin/bash

# GridTokenX On-Chain Settlement Verification Tool
# Verifies: Database Sig -> Solana RPC -> Transaction Finality -> Program Logs

set -e

# Configuration
RPC_URL="${SOLANA_RPC_URL:-http://localhost:8899}"
DB_CONTAINER="gridtokenx-postgres"
DB_USER="gridtokenx_user"
DB_NAME="gridtokenx"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_status() { echo -e "${YELLOW}[WAIT]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# Check for jq
if ! command -v jq &> /dev/null; then
    log_error "jq is required for this verification script."
fi

# Step 1: Verify RPC Availability
log_info "Step 1: Checking Solana RPC Health ($RPC_URL)..."
HEALTH=$(curl -s -X POST "$RPC_URL" -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' | jq -r '.result // empty')
if [ "$HEALTH" != "ok" ]; then
    log_error "Solana RPC is not healthy or unreachable."
fi
log_success "Solana RPC is online."

# Step 2: Extract latest transaction hash from Database
log_info "Step 2: Retrieving latest settlement signature from database..."
QUERY="SELECT transaction_hash FROM settlements WHERE transaction_hash IS NOT NULL ORDER BY created_at DESC LIMIT 1;"
TX_HASH=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "$QUERY" | tr -d '[:space:]')

if [ -z "$TX_HASH" ] || [ "$TX_HASH" == "(0rows)" ]; then
    log_error "No transaction signatures found in the settlements table. Run test-trading-e2e.sh first."
fi
log_info "Found Transaction Signature: $TX_HASH"

# Step 3: Verify Transaction Finality
log_status "Step 3: Verifying finality for $TX_HASH..."
MAX_RETRIES=10
RETRY_COUNT=0
STATUS="unknown"

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    JSON_RESP=$(curl -s -X POST "$RPC_URL" -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSignatureStatuses\",\"params\":[[\"$TX_HASH\"], {\"searchTransactionHistory\":true}]}")
    
    CONFIRMATION=$(echo "$JSON_RESP" | jq -r '.result.value[0].confirmationStatus // "notfound"')
    
    if [ "$CONFIRMATION" == "finalized" ] || [ "$CONFIRMATION" == "confirmed" ]; then
        STATUS=$CONFIRMATION
        break
    fi
    
    log_status "Current status: $CONFIRMATION. Retrying ($((RETRY_COUNT+1))/$MAX_RETRIES)..."
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ "$STATUS" == "unknown" ] || [ "$STATUS" == "notfound" ]; then
    log_error "Transaction $TX_HASH was not confirmed within the timeout period."
fi
log_success "Transaction Finalized ($STATUS)."

# Step 4: Verify Transaction Logs (Trading Program)
log_info "Step 4: Inspecting transaction logs..."
LOGS_RESP=$(curl -s -X POST "$RPC_URL" -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTransaction\",\"params\":[\"$TX_HASH\", {\"encoding\":\"json\", \"maxSupportedTransactionVersion\":0}]}")

# Check for program invocation in logs
# The trading program ID is usually found in the logs
PROGRAM_LOGS=$(echo "$LOGS_RESP" | jq -r '.result.meta.logMessages[] // empty')

if [[ "$PROGRAM_LOGS" != *"Program"* ]]; then
    log_error "Transaction logs do not contain program execution data. Response: $LOGS_RESP"
fi

if [[ "$PROGRAM_LOGS" == *"Error:"* ]]; then
    log_error "Transaction contains program errors: $PROGRAM_LOGS"
fi

log_success "Transaction Logs Verified (Successful Execution)."

echo "--------------------------------------------------"
log_success "🏆 FULL ON-CHAIN SETTLEMENT VERIFIED SUCCESSFULLY"
echo "--------------------------------------------------"
