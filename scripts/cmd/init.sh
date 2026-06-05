#!/bin/bash
# GridTokenX - Init command (blockchain deployment)

cmd_init() {
    # Load Environment
    if [ -f "$PROJECT_ROOT/.env" ]; then
        set -a; source "$PROJECT_ROOT/.env"; set +a
    fi
    # Fallback default RPC_URL and ANCHOR_DIR
    RPC_URL=${RPC_URL:-"http://localhost:8899"}
    ANCHOR_DIR=${ANCHOR_DIR:-"$PROJECT_ROOT/gridtokenx-anchor"}
    DEV_WALLET=${DEV_WALLET:-"$PROJECT_ROOT/infra/solana/dev-wallet.json"}

    show_banner
    log_info "Initializing Blockchain..."
    echo ""

    if ! command -v anchor &> /dev/null; then
        log_error "anchor CLI is not installed. See https://www.anchor-lang.com/docs/installation"
    fi
    if ! command -v solana &> /dev/null; then
        log_error "solana CLI is not installed"
    fi

    log_info "Building Anchor Programs..."
    cd "$ANCHOR_DIR"
    export PATH="$HOME/.cargo/bin:$PATH"
    anchor build

    if ! curl -s "$RPC_URL/health" > /dev/null 2>&1; then
        log_warn "Solana validator not running. Starting it..."
        
        solana_validator_start "$PROJECT_ROOT/test-ledger" "$PROJECT_ROOT/solana.log" ""
        wait_for_solana
    fi

    log_info "Deploying Programs (Using existing keypairs for consistent IDs)..."

    deploy_program() {
        local NAME=$1
        local ID=$2
        log_info "Deploying $NAME ($ID)..."
        local KEYPAIR="$ANCHOR_DIR/target/deploy/${NAME}-keypair.json"
        solana program deploy \
            --program-id "$KEYPAIR" \
            "$ANCHOR_DIR/target/deploy/${NAME}.so" \
            --url "$RPC_URL" 2>/dev/null || log_warn "Deployment may have failed or already exists (ID: $ID)"
    }

    local REGISTRY_ID=$(grep -E "^registry =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    local ENERGY_TOKEN_ID=$(grep -E "^energy_token =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    local TRADING_ID=$(grep -E "^trading =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    local ORACLE_ID=$(grep -E "^oracle =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    local GOVERNANCE_ID=$(grep -E "^governance =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)

    deploy_program "registry" "$REGISTRY_ID"
    deploy_program "energy_token" "$ENERGY_TOKEN_ID"
    deploy_program "trading" "$TRADING_ID"
    deploy_program "oracle" "$ORACLE_ID"
    deploy_program "governance" "$GOVERNANCE_ID"

    log_info "Bootstrapping on-chain accounts..."
    cd "$ANCHOR_DIR"
    export ANCHOR_PROVIDER_URL="$RPC_URL"
    export ANCHOR_WALLET="$DEV_WALLET"
    sleep 5

    local dev_pubkey=$(solana-keygen pubkey "$DEV_WALLET" 2>/dev/null || echo "")
    if [ -n "$dev_pubkey" ]; then
        log_info "Authorizing dev-wallet ($dev_pubkey) as Oracle API Gateway..."
        ORACLE_API_GATEWAY="$dev_pubkey" npx tsx scripts/bootstrap.ts || log_warn "Bootstrap script failed, but continuing..."
    else
        npx tsx scripts/bootstrap.ts || log_warn "Bootstrap script failed, but continuing..."
    fi

    log_info "Initializing Registry Shards..."
    npx tsx scripts/init-shards.ts || log_warn "Shard initialization failed, but continuing..."

    log_info "Extracting PDAs and Mint addresses..."
    local pda_config=$(npx tsx scripts/get_pdas.ts 2>/dev/null || echo "")
    local energy_mint=$(echo "$pda_config" | grep "ENERGY_TOKEN_MINT=" | cut -d'=' -f2)
    local currency_mint=$(echo "$pda_config" | grep "CURRENCY_TOKEN_MINT=" | cut -d'=' -f2)
    local registry_pda=$(echo "$pda_config" | grep "REGISTRY_PDA=" | cut -d'=' -f2)
    local trading_market_pda=$(echo "$pda_config" | grep "MARKET_PDA=" | cut -d'=' -f2)
    local collector_wallet=${dev_pubkey:-}

    propagate_program_ids \
        "$REGISTRY_ID" "$ENERGY_TOKEN_ID" "$TRADING_ID" "$ORACLE_ID" "$GOVERNANCE_ID" \
        "$energy_mint" "$currency_mint" "$registry_pda" "$trading_market_pda" \
        "$collector_wallet" "$collector_wallet" "$collector_wallet"

    log_success "Blockchain initialization complete!"
}
