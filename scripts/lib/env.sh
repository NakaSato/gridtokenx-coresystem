#!/bin/bash
# GridTokenX - Environment file management and program ID propagation

# Update environment file
update_env_file() {
    local file=$1
    local var=$2
    local value=$3
    
    if [ ! -f "$file" ]; then
        # Create file if it doesn't exist
        touch "$file"
    fi

    if grep -q "^${var}=" "$file"; then
        # Platform-agnostic sed in-place update
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${var}=.*|${var}=${value}|" "$file"
        else
            sed -i "s|^${var}=.*|${var}=${value}|" "$file"
        fi
    else
        echo "${var}=${value}" >> "$file"
    fi
}

# Propagate program IDs and metadata to all services
propagate_program_ids() {
    local registry_id=$1
    local energy_token_id=$2
    local trading_id=$3
    local oracle_id=$4
    local governance_id=$5
    local energy_mint=$6
    local currency_mint=$7
    local registry_pda=$8
    local trading_market_pda=$9
    local fee_col=${10:-""}
    local wheel_col=${11:-""}
    local loss_col=${12:-""}

    log_info "Propagating program IDs to services..."
    
    # Root .env
    local root_env="$PROJECT_ROOT/.env"
    update_env_file "$root_env" "SOLANA_REGISTRY_PROGRAM_ID" "$registry_id"
    update_env_file "$root_env" "SOLANA_ENERGY_TOKEN_PROGRAM_ID" "$energy_token_id"
    update_env_file "$root_env" "SOLANA_TRADING_PROGRAM_ID" "$trading_id"
    update_env_file "$root_env" "SOLANA_ORACLE_PROGRAM_ID" "$oracle_id"
    update_env_file "$root_env" "SOLANA_GOVERNANCE_PROGRAM_ID" "$governance_id"
    update_env_file "$root_env" "ENERGY_TOKEN_MINT" "$energy_mint"
    [ -n "$currency_mint" ] && update_env_file "$root_env" "CURRENCY_TOKEN_MINT" "$currency_mint"
    [ -n "$registry_pda" ] && update_env_file "$root_env" "REGISTRY_PDA" "$registry_pda"
    [ -n "$trading_market_pda" ] && update_env_file "$root_env" "TRADING_MARKET_PDA" "$trading_market_pda"
    update_env_file "$root_env" "SOLANA_RPC_URL" "$RPC_URL"

    # IAM Service
    local iam_service_env="$PROJECT_ROOT/gridtokenx-iam-service/.env"
    update_env_file "$iam_service_env" "SOLANA_REGISTRY_PROGRAM_ID" "$registry_id"
    update_env_file "$iam_service_env" "SOLANA_ENERGY_TOKEN_PROGRAM_ID" "$energy_token_id"
    update_env_file "$iam_service_env" "SOLANA_TRADING_PROGRAM_ID" "$trading_id"
    update_env_file "$iam_service_env" "SOLANA_ORACLE_PROGRAM_ID" "$oracle_id"
    update_env_file "$iam_service_env" "SOLANA_GOVERNANCE_PROGRAM_ID" "$governance_id"
    update_env_file "$iam_service_env" "ENERGY_TOKEN_MINT" "$energy_mint"
    [ -n "$currency_mint" ] && update_env_file "$iam_service_env" "CURRENCY_TOKEN_MINT" "$currency_mint"
    [ -n "$registry_pda" ] && update_env_file "$iam_service_env" "REGISTRY_PDA" "$registry_pda"
    update_env_file "$iam_service_env" "SOLANA_RPC_URL" "$RPC_URL"
    
    # Oracle Bridge
    local oracle_bridge_env="$PROJECT_ROOT/gridtokenx-oracle-bridge/.env"
    update_env_file "$oracle_bridge_env" "SOLANA_REGISTRY_PROGRAM_ID" "$registry_id"
    update_env_file "$oracle_bridge_env" "SOLANA_ORACLE_PROGRAM_ID" "$oracle_id"
    
    # Trading Service
    local trading_service_env="$PROJECT_ROOT/gridtokenx-trading-service/.env"
    update_env_file "$trading_service_env" "SOLANA_TRADING_PROGRAM_ID" "$trading_id"
    update_env_file "$trading_service_env" "ENERGY_TOKEN_MINT" "$energy_mint"
    [ -n "$currency_mint" ] && update_env_file "$trading_service_env" "CURRENCY_TOKEN_MINT" "$currency_mint"
    update_env_file "$trading_service_env" "SOLANA_RPC_URL" "$RPC_URL"
    [ -n "$fee_col" ] && update_env_file "$trading_service_env" "FEE_COLLECTOR_WALLET" "$fee_col"
    [ -n "$wheel_col" ] && update_env_file "$trading_service_env" "WHEELING_COLLECTOR_WALLET" "$wheel_col"
    [ -n "$loss_col" ] && update_env_file "$trading_service_env" "LOSS_COLLECTOR_WALLET" "$loss_col"

    # Explorer
    local explorer_env="$PROJECT_ROOT/gridtokenx-explorer/.env"
    update_env_file "$explorer_env" "NEXT_PUBLIC_REGISTRY_PROGRAM_ID" "$registry_id"
    update_env_file "$explorer_env" "NEXT_PUBLIC_TOKEN_PROGRAM_ID" "$energy_token_id"
    update_env_file "$explorer_env" "NEXT_PUBLIC_TRADING_PROGRAM_ID" "$trading_id"
    update_env_file "$explorer_env" "NEXT_PUBLIC_ORACLE_PROGRAM_ID" "$oracle_id"
    update_env_file "$explorer_env" "NEXT_PUBLIC_GOVERNANCE_PROGRAM_ID" "$governance_id"
    update_env_file "$explorer_env" "NEXT_PUBLIC_SOLANA_RPC_HTTP" "$RPC_URL"
    update_env_file "$explorer_env" "NEXT_PUBLIC_SOLANA_RPC_WS" "$WS_URL"

    # Trading
    local trading_env="$PROJECT_ROOT/gridtokenx-trading/.env"
    update_env_file "$trading_env" "NEXT_PUBLIC_REGISTRY_PROGRAM_ID" "$registry_id"
    update_env_file "$trading_env" "NEXT_PUBLIC_ENERGY_TOKEN_PROGRAM_ID" "$energy_token_id"
    update_env_file "$trading_env" "NEXT_PUBLIC_TRADING_PROGRAM_ID" "$trading_id"
    update_env_file "$trading_env" "NEXT_PUBLIC_ORACLE_PROGRAM_ID" "$oracle_id"
    update_env_file "$trading_env" "NEXT_PUBLIC_GOVERNANCE_PROGRAM_ID" "$governance_id"
    update_env_file "$trading_env" "NEXT_PUBLIC_ENERGY_TOKEN_MINT" "$energy_mint"
    update_env_file "$trading_env" "NEXT_PUBLIC_SOLANA_RPC_URL" "$RPC_URL"
    update_env_file "$trading_env" "NEXT_PUBLIC_SOLANA_WS_URL" "$WS_URL"

    log_success "Program IDs propagated to all services."
}
