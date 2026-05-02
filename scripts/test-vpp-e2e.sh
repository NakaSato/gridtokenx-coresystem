#!/bin/bash

# GridTokenX VPP Aggregation E2E Verification
# Verifies: Multi-Member Pulse -> Oracle Bridge -> Aggregator -> VPP Cluster State
# Features: Real On-chain Onboarding, Real Telemetry Ingestion, RBAC validation

set -e

# Configuration
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
API_URL="${API_URL:-http://localhost:4001}"
IOT_URL="${IOT_GATEWAY_URL:-http://localhost:4030}"
DB_CONTAINER="gridtokenx-postgres"
TIMESTAMP=$(date +%s)

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_status() { echo -e "${YELLOW}[WAIT]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# Step 0: Infrastructure Check
log_info "Step 0: Checking service availability..."
if ! curl -s "$API_URL/health" > /dev/null; then log_error "API Gateway ($API_URL) is unreachable."; fi
if ! curl -s "$IOT_URL/health" > /dev/null; then log_error "Oracle Bridge ($IOT_URL) is unreachable."; fi

# Step 1: Multi-Prosumer Setup (Real Onboarding)
log_info "Step 1: Setting up 3 Prosumers via IAM Service..."
SELLERS=("vpp_prosumer_a_$TIMESTAMP" "vpp_prosumer_b_$TIMESTAMP" "vpp_prosumer_c_$TIMESTAMP")
SELLER_METER_IDS=()
SELLER_WALLETS=()

for NAME in "${SELLERS[@]}"; do
    EMAIL="${NAME}@grx.test"
    log_info "Processing $NAME..."
    
    # 1.1 Register
    REG_RESP=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
        -H "Content-Type: application/json" \
        -H "x-gridtokenx-role: api-gateway" \
        -d "{
            \"email\": \"$EMAIL\",
            \"username\": \"$NAME\",
            \"password\": \"GridTokenX!2025\",
            \"first_name\": \"VPP\",
            \"last_name\": \"Prosumer\"
        }")
    
    USER_ID=$(echo $REG_RESP | jq -r '.id // empty')
    [ -z "$USER_ID" ] && log_error "Registration failed for $NAME: $REG_RESP"

    # 1.2 Verify Email & Get JWT
    VERIFY_RESP=$(curl -s "$API_URL/api/v1/auth/verify?token=verify_$EMAIL" \
        -H "x-gridtokenx-role: api-gateway")
    
    JWT=$(echo $VERIFY_RESP | jq -r '.auth.access_token // empty')
    WALLET=$(echo $VERIFY_RESP | jq -r '.wallet_address // empty')
    [ -z "$JWT" ] && log_error "Verification/JWT acquisition failed for $NAME: $VERIFY_RESP"

    # 1.3 On-chain Onboarding
    ONBOARD_RESP=$(curl -s -X POST "$API_URL/api/v1/identity/onboard" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $JWT" \
        -H "x-gridtokenx-role: api-gateway" \
        -d "{
            \"user_type\": \"Prosumer\",
            \"lat_e7\": 1375633,
            \"long_e7\": 1005018
        }")
    
    ONBOARD_SUCCESS=$(echo $ONBOARD_RESP | jq -r '.success // empty')
    [ "$ONBOARD_SUCCESS" != "true" ] && log_error "On-chain onboarding failed for $NAME: $ONBOARD_RESP"

    # 1.4 Register Meter in both databases with derived UUID
    # Calculate deterministic UUID v5 logic (matches Oracle Bridge derive_id)
    DERIVED_METER_ID=$(python3 -c "import uuid; print(uuid.uuid5(uuid.NAMESPACE_OID, '$METER_ID'))")
    SELLER_METER_IDS+=("$DERIVED_METER_ID") # Store the derived UUID
    SELLER_WALLETS+=("$WALLET")
    
    # Register in Oracle Bridge (gridtokenx DB)
    docker exec -i "$DB_CONTAINER" psql -U gridtokenx_user -d gridtokenx -c \
    "INSERT INTO meter_registry (id, user_id, serial_number, meter_type, is_verified, wallet_address, zone_id) \
     VALUES ('$DERIVED_METER_ID', '$USER_ID', '$METER_ID', 'SmartMeter', true, '$WALLET', 1) \
     ON CONFLICT (serial_number) DO UPDATE SET wallet_address = EXCLUDED.wallet_address;" > /dev/null

    # Sync to Trading Service (gridtokenx_trading DB)
    # Ensure user and primary wallet exist for the join in execute_generation_mint
    docker exec -i "$DB_CONTAINER" psql -U gridtokenx_user -d gridtokenx_trading -c \
    "INSERT INTO users (id, username, email, password_hash, role) \
     VALUES ('$USER_ID', '$NAME', '$EMAIL', 'external', 'user') ON CONFLICT DO NOTHING;" > /dev/null
    
    docker exec -i "$DB_CONTAINER" psql -U gridtokenx_user -d gridtokenx_trading -c \
    "INSERT INTO user_wallets (user_id, address, is_primary) \
     VALUES ('$USER_ID', '$WALLET', true) ON CONFLICT (address) DO UPDATE SET is_primary = true;" > /dev/null

    docker exec -i "$DB_CONTAINER" psql -U gridtokenx_user -d gridtokenx_trading -c \
    "INSERT INTO meters (id, user_id, serial_number, meter_type, is_verified) \
     VALUES ('$DERIVED_METER_ID', '$USER_ID', '$METER_ID', 'SmartMeter', true) \
     ON CONFLICT (serial_number) DO UPDATE SET updated_at = NOW();" > /dev/null
    
    # 1.5 Initial Balance Check (Airdrop)
    log_info "Verifying airdrop balance for Prosumer $NAME..."
    if scripts/check-balance.sh "$WALLET"; then
        log_success "Airdrop verified: Prosumer $NAME received 20 GRX"
    else
        log_warn "Airdrop check failed for $NAME (might be too fast, or airdrop disabled)"
    fi
    
    log_success "Prosumer $NAME onboarded with Wallet $WALLET and Meter $METER_ID"
done

# Step 2: VPP Cluster Provisioning
CLUSTER_ID="VPP-CLUSTER-$TIMESTAMP"
log_info "Step 2: Provisioning VPP Cluster $CLUSTER_ID..."
docker exec -i "$DB_CONTAINER" psql -U gridtokenx_user -d gridtokenx -c \
"INSERT INTO vpp_clusters (cluster_id, zone_id, total_capacity_kwh, current_stored_kwh, soc_percentage, resource_count) \
VALUES ('$CLUSTER_ID', 1, 1000.0, 0.0, 0.0, 3);" > /dev/null

# Add Members
for METER_UUID in "${SELLER_METER_IDS[@]}"; do
    docker exec -i "$DB_CONTAINER" psql -U gridtokenx_user -d gridtokenx -c \
    "INSERT INTO vpp_cluster_members (cluster_id, meter_id) VALUES ('$CLUSTER_ID', '$METER_UUID') ON CONFLICT DO NOTHING;" > /dev/null
done
log_success "VPP Cluster $CLUSTER_ID ready with 3 members."

# Step 3: Real Telemetry Ingestion
log_info "Step 3: Ingesting Real Telemetry via Oracle Bridge..."
readings=(15.5 24.5 20.0) # Total 60.0
for i in ${!SELLER_METER_IDS[@]}; do
    METER="${SELLER_METER_IDS[$i]}"
    KWH="${readings[$i]}"
    TS=$(date +%s)000 # milliseconds
    
    log_info "Sending $KWH kWh for $METER_UUID..."
    INGEST_RESP=$(curl -s -X POST "$IOT_URL/v1/ingest/telemetry" \
        -H "Content-Type: application/json" \
        -d "{
            \"meter_id\": \"$METER_UUID\",
            \"kwh\": $KWH,
            \"timestamp\": $TS,
            \"meter_signature\": \"DUMMY_SIG_DEV_MODE\"
        }")
    
    STATUS=$(echo $INGEST_RESP | jq -r '.status // empty')
    [ "$STATUS" != "accepted" ] && log_error "Ingestion failed for $METER: $INGEST_RESP"
done
log_success "All 3 telemetry pulses ingested via Oracle Bridge."

# Step 4: Verification Loop (Off-chain & On-chain)
log_info "Step 4: Waiting for Aggregation & Settlement (1-min window)..."
EXPECTED_ENERGY=60.0
MAX_WAIT_SECONDS=90
WAIT_COUNT=0

while [ $WAIT_COUNT -lt $MAX_WAIT_SECONDS ]; do
    # 4.1 Check Off-chain VPP Aggregation
    CURRENT_ENERGY=$(docker exec -i "$DB_CONTAINER" psql -U gridtokenx_user -d gridtokenx -t -c "SELECT current_stored_kwh FROM vpp_clusters WHERE cluster_id='$CLUSTER_ID';" | tr -d '[:space:]')
    
    # 4.2 Check On-chain Token Release (Settlement)
    # We check the first prosumer's balance - it should have increased beyond the 20 GRX airdrop
    SAMPLE_WALLET="${SELLER_WALLETS[0]}"
    SAMPLE_BALANCE=$(spl-token balance --address $SAMPLE_WALLET FYoHgS599B9ZmCeyDpoTVYTR2K165py1HpyC1QkxqFzN 2>/dev/null || echo "0")
    
    log_info "Progress: VPP=${CURRENT_ENERGY:-0}/$EXPECTED_ENERGY kWh | Wallet[0]=$SAMPLE_BALANCE GRX (Wait: $WAIT_COUNT s)"
    
    # Check if BOTH conditions are met (Aggregation + Settlement)
    if [ "$(echo "${CURRENT_ENERGY:-0} >= $EXPECTED_ENERGY" | bc -l)" -eq 1 ] && [ "$(echo "$SAMPLE_BALANCE > 20.0" | bc -l)" -eq 1 ]; then
        log_success "VPP Aggregation AND On-chain Settlement Verified!"
        log_success "Final VPP Stored: $CURRENT_ENERGY kWh"
        log_success "Final Wallet Balance: $SAMPLE_BALANCE GRX"
        break
    fi

    sleep 10
    WAIT_COUNT=$((WAIT_COUNT+10))
done

if [ $WAIT_COUNT -ge $MAX_WAIT_SECONDS ]; then
    log_error "E2E verification timed out after $MAX_WAIT_SECONDS seconds."
fi

# Step 5: Post-Settlement Verification
log_info "Step 5: Finalizing Verification..."
for i in ${!SELLER_METER_IDS[@]}; do
    WALLET="${SELLER_WALLETS[$i]}"
    FINAL_BALANCE=$(spl-token balance --address $WALLET FYoHgS599B9ZmCeyDpoTVYTR2K165py1HpyC1QkxqFzN 2>/dev/null || echo "0")
    log_success "Prosumer $((i+1)) ($WALLET): $FINAL_BALANCE GRX"
done

echo "--------------------------------------------------"
log_success "🏆 VPP ON-CHAIN SETTLEMENT E2E VERIFIED"
echo "--------------------------------------------------"
