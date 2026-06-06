#!/bin/bash
# GridTokenX - Start command and modular start functions

# ============================================================================
# Modular Start Functions
# ============================================================================

start_core_services() {
    local all_docker=${1:-false}

    if [ "$all_docker" = true ]; then
        log_info "Starting ALL services in Docker (OrbStack)..."
    else
        log_info "Starting Core OrbStack services..."
    fi

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running."
    fi

    cd "$PROJECT_ROOT"

    if [ "$all_docker" = true ]; then
        docker-compose up -d
    else
        docker-compose up -d postgres redis mailpit apisix envoy rabbitmq kafka-cmd
        # Ensure Docker versions of application services are stopped to prevent port conflicts (native execution preferred)
        docker stop gridtokenx-trading-service gridtokenx-iam-service gridtokenx-oracle-bridge gridtokenx-noti-service >/dev/null 2>&1 || true
    fi

    wait_for_postgres
    wait_for_redis
    log_success "Docker services ready"
}

start_blockchain_services() {
    echo ""
    log_info "Starting Solana test validator..."
    mkdir -p "$PROJECT_ROOT/scripts/logs"
    
    solana_validator_start "$PROJECT_ROOT/test-ledger" "$PROJECT_ROOT/scripts/logs/validator.log" ""
    wait_for_solana

    # Fund wallets
    log_info "Funding wallets..."
    solana airdrop 10 $(solana address) --url "$RPC_URL" 2>/dev/null || true

    if [ ! -f "$DEV_WALLET" ]; then
        if [ -f "$PROJECT_ROOT/dev-wallet.json" ]; then
            cp "$PROJECT_ROOT/dev-wallet.json" "$DEV_WALLET"
        else
            solana-keygen new --no-bip39-passphrase --outfile "$DEV_WALLET" 2>/dev/null
        fi
    fi

    local dev_pubkey=$(solana-keygen pubkey "$DEV_WALLET")
    solana airdrop 100 "$dev_pubkey" --url "$RPC_URL" 2>/dev/null || true
    log_success "Wallets funded"

    # Initialize blockchain
    cmd_init
}

start_application_services() {
    local skip_ui=$1
    local native_mode=${2:-false}

    echo ""
    log_info "Starting application backend services..."
    mkdir -p "$PROJECT_ROOT/scripts/logs"

    # Load Environment
    if [ -f "$PROJECT_ROOT/.env" ]; then
        log_info "Loading environment from $PROJECT_ROOT/.env"
        set -a; source "$PROJECT_ROOT/.env"; set +a
    elif [ -f "$PROJECT_ROOT/gridtokenx-iam-service/.env" ]; then
        log_info "Loading environment from IAM service"
        set -a; source "$PROJECT_ROOT/gridtokenx-iam-service/.env"; set +a
    fi

    # Ensure native services use localhost for OTEL Collector
    export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4317"
    export OTEL_ENABLED="true"

    # Default Environment Variables for Native Execution
    export IAM_DATABASE_URL=${IAM_DATABASE_URL:-"postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx"}
    export IAM_GRPC_PORT=${IAM_GRPC_PORT:-"5010"}
    export TRADING_DATABASE_URL=${TRADING_DATABASE_URL:-"postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx_trading"}
    export NOTI_DATABASE_URL=${NOTI_DATABASE_URL:-"postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx_noti"}
    export REDIS_URL=${REDIS_URL:-"redis://localhost:7010"}
    export SOLANA_RPC_URL=${SOLANA_RPC_URL:-"http://localhost:8899"}
    export SOLANA_WS_URL=${SOLANA_WS_URL:-"ws://localhost:8900"}
    export KAFKA_BOOTSTRAP_SERVERS=${KAFKA_BOOTSTRAP_SERVERS:-"localhost:29001"}
    export KAFKA_BROKERS=${KAFKA_BROKERS:-"localhost:29001"}
    export CHAIN_BRIDGE_URL=${CHAIN_BRIDGE_URL:-"http://localhost:5040"}
    export ENCRYPTION_SECRET=${ENCRYPTION_SECRET:-"supersecretencryptionkey"}
    export OWS_VAULT_PATH=${OWS_VAULT_PATH:-"$HOME/.local/share/gridtokenx/ows-vault"}
    export RABBITMQ_URL=${RABBITMQ_URL:-"amqp://gridtokenx:rabbitmq_secret_2025@localhost:9030"}
    export GRIDTOKENX_API_KEYS=${GRIDTOKENX_API_KEYS:-"engineering-department-api-key-2025"}

    # Trading specific
    local default_energy_mint=""
    local default_currency_mint=""
    if [ -z "$ENERGY_TOKEN_MINT" ] || [ -z "$CURRENCY_TOKEN_MINT" ]; then
        log_info "Extracting default Mint addresses..."
        local pda_config=$(npx tsx "$ANCHOR_DIR/scripts/get_pdas.ts" 2>/dev/null || echo "")
        default_energy_mint=$(echo "$pda_config" | grep "ENERGY_TOKEN_MINT=" | cut -d'=' -f2)
        default_currency_mint=$(echo "$pda_config" | grep "CURRENCY_TOKEN_MINT=" | cut -d'=' -f2)
    fi

    export ENERGY_TOKEN_MINT=${ENERGY_TOKEN_MINT:-$default_energy_mint}
    export CURRENCY_TOKEN_MINT=${CURRENCY_TOKEN_MINT:-$default_currency_mint}
    export FEE_COLLECTOR_WALLET=${FEE_COLLECTOR_WALLET:?FEE_COLLECTOR_WALLET must be set (infra/ removed)}

    # Noti specific (uses APP prefix)
    export APP__PORT=${APP__PORT:-"5050"}
    export APP__DATABASE_URL=${APP__DATABASE_URL:-"postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx_noti"}
    export APP__KAFKA_BROKERS=${APP__KAFKA_BROKERS:-"localhost:29001"}
    export APP__REDIS_URL=${APP__REDIS_URL:-"redis://localhost:7010"}
    export APP__RABBITMQ_URL=${APP__RABBITMQ_URL:-"amqp://gridtokenx:rabbitmq_secret_2025@localhost:9030"}
    export APP__LOG_LEVEL=${APP__LOG_LEVEL:-"info"}

    if [ "$native_mode" = true ]; then
        _start_native_services "$skip_ui"
    else
        _start_terminal_services "$skip_ui"
    fi
}

_start_native_services() {
    local skip_ui=$1
    log_info "Starting services as native background processes..."

    run_in_background "Chain Bridge" \
        "CHAIN_BRIDGE_INSECURE=true SOLANA_RPC_URL=$SOLANA_RPC_URL $PROJECT_ROOT/gridtokenx-chain-bridge/target/debug/gridtokenx-chain-bridge" \
        "$PROJECT_ROOT" \
        "$PROJECT_ROOT/scripts/logs/chain-bridge.log"
    wait_for_port "Chain Bridge" 5040 30

    run_in_background "IAM Service" \
        "DATABASE_URL=$IAM_DATABASE_URL REDIS_URL=$REDIS_URL IAM_PORT=4010 OWS_VAULT_PATH=$OWS_VAULT_PATH ENCRYPTION_SECRET=$ENCRYPTION_SECRET $PROJECT_ROOT/gridtokenx-iam-service/target/debug/gridtokenx-iam-service" \
        "$PROJECT_ROOT" \
        "$PROJECT_ROOT/scripts/logs/iam.log"
    wait_for_port "IAM gRPC" 5010 30

    run_in_background "Trading Service" \
        "DATABASE_URL=$TRADING_DATABASE_URL REDIS_URL=$REDIS_URL SOLANA_RPC_URL=$SOLANA_RPC_URL SOLANA_WS_URL=$SOLANA_WS_URL RUST_LOG=info ENABLE_SETTLEMENT_PROCESSOR=true $PROJECT_ROOT/gridtokenx-trading-service/target/debug/trading-service" \
        "$PROJECT_ROOT" \
        "$PROJECT_ROOT/scripts/logs/trading.log"

    # ENVIRONMENT=production makes the REST /v1/private-network/ingest path enforce Ed25519
    # signature verification (reject tampered/unknown/wrong-key). Without it the handler
    # falls through and accepts unverified telemetry as 202 — see docs/E2E_IMPL_PLAN.md.
    run_in_background "Oracle Bridge" \
        "ENVIRONMENT=production IAM_SERVICE_URL=http://127.0.0.1:4010 GRIDTOKENX_API_KEYS=\"$GRIDTOKENX_API_KEYS\" RUST_LOG=info $PROJECT_ROOT/gridtokenx-oracle-bridge/target/debug/gridtokenx-oracle-bridge" \
        "$PROJECT_ROOT" \
        "$PROJECT_ROOT/scripts/logs/oracle-bridge.log"
    wait_for_port "Oracle Bridge" 4030 30

    run_in_background "Noti Service" \
        "DATABASE_URL=$NOTI_DATABASE_URL REDIS_URL=$REDIS_URL RUST_LOG=info $PROJECT_ROOT/gridtokenx-noti-service/target/debug/noti-server" \
        "$PROJECT_ROOT" \
        "$PROJECT_ROOT/scripts/logs/noti.log"
    wait_for_port "Noti gRPC" 5050 30

    wait_for_service "APISIX" "http://localhost:4001/api/v1/system/config" 60 2

    if [ "$skip_ui" = false ]; then
        _start_frontend_uis_background
    fi
}

_start_terminal_services() {
    local skip_ui=$1

    run_in_terminal "Chain Bridge" \
        "CHAIN_BRIDGE_INSECURE=true SOLANA_RPC_URL=$SOLANA_RPC_URL $PROJECT_ROOT/gridtokenx-chain-bridge/target/debug/gridtokenx-chain-bridge > $PROJECT_ROOT/scripts/logs/chain-bridge.log 2>&1" \
        "$PROJECT_ROOT"
    wait_for_port "Chain Bridge" 5040 30

    run_in_terminal "IAM Service" \
        "DATABASE_URL=$IAM_DATABASE_URL REDIS_URL=$REDIS_URL IAM_PORT=4010 OWS_VAULT_PATH=$OWS_VAULT_PATH ENCRYPTION_SECRET=$ENCRYPTION_SECRET $PROJECT_ROOT/gridtokenx-iam-service/target/debug/gridtokenx-iam-service > $PROJECT_ROOT/scripts/logs/iam.log 2>&1" \
        "$PROJECT_ROOT"
    wait_for_port "IAM gRPC" 5010 30

    run_in_terminal "Trading Service" \
        "DATABASE_URL=$TRADING_DATABASE_URL REDIS_URL=$REDIS_URL SOLANA_RPC_URL=$SOLANA_RPC_URL SOLANA_WS_URL=$SOLANA_WS_URL RUST_LOG=info ENABLE_SETTLEMENT_PROCESSOR=true $PROJECT_ROOT/gridtokenx-trading-service/target/debug/trading-service > $PROJECT_ROOT/scripts/logs/trading.log 2>&1" \
        "$PROJECT_ROOT"
    wait_for_port "Trading gRPC" 8092 60

    # ENVIRONMENT=production enforces REST telemetry signature verification (see above / docs).
    run_in_terminal "Oracle Bridge" \
        "ENVIRONMENT=production IAM_SERVICE_URL=http://127.0.0.1:4010 GRIDTOKENX_API_KEYS=\"$GRIDTOKENX_API_KEYS\" RUST_LOG=info $PROJECT_ROOT/gridtokenx-oracle-bridge/target/debug/gridtokenx-oracle-bridge > $PROJECT_ROOT/scripts/logs/oracle-bridge.log 2>&1" \
        "$PROJECT_ROOT"
    wait_for_port "Oracle Bridge" 4030 30

    run_in_terminal "Noti Service" \
        "DATABASE_URL=$NOTI_DATABASE_URL REDIS_URL=$REDIS_URL RUST_LOG=info $PROJECT_ROOT/gridtokenx-noti-service/target/debug/noti-server > $PROJECT_ROOT/scripts/logs/noti.log 2>&1" \
        "$PROJECT_ROOT"
    wait_for_port "Noti gRPC" 5050 30

    wait_for_service "APISIX" "http://localhost:4001/api/v1/system/config" 60 2

    if [ "$skip_ui" = false ]; then
        _start_frontend_uis_terminal
    fi
}

_start_frontend_uis_background() {
    echo ""
    log_info "Starting frontend UIs as background processes..."

    if [ -f "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/backend/pyproject.toml" ]; then
        run_in_background "Simulator API" "PORT=12010 uv run start" \
            "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/backend" \
            "$PROJECT_ROOT/scripts/logs/simulator-api.log"
    fi
    if [ -d "$PROJECT_ROOT/gridtokenx-trading/node_modules" ]; then
        run_in_background "Trading UI" "bun run dev --port 11001" \
            "$PROJECT_ROOT/gridtokenx-trading" "$PROJECT_ROOT/scripts/logs/trading-ui.log"
    fi
    if [ -d "$PROJECT_ROOT/gridtokenx-explorer/node_modules" ]; then
        run_in_background "Explorer UI" "bun run dev --port 11002" \
            "$PROJECT_ROOT/gridtokenx-explorer" "$PROJECT_ROOT/scripts/logs/explorer-ui.log"
    fi
    if [ -d "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/frontend/node_modules" ]; then
        run_in_background "Simulator UI" "bun run dev --port 12011" \
            "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/frontend" "$PROJECT_ROOT/scripts/logs/simulator-ui.log"
    fi
    if [ -d "$PROJECT_ROOT/gridtokenx-admin/node_modules" ]; then
        run_in_background "Admin UI" "bun run dev" \
            "$PROJECT_ROOT/gridtokenx-admin" "$PROJECT_ROOT/scripts/logs/admin-ui.log"
    fi
}

_start_frontend_uis_terminal() {
    echo ""
    log_info "Starting frontend UIs..."

    if [ -d "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/frontend/node_modules" ]; then
        run_in_terminal "Simulator UI" "bun run dev --port 12011" "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/frontend"
    fi
    if [ -f "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/backend/pyproject.toml" ]; then
        run_in_terminal "Simulator API" "PORT=12010 uv run start" "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/backend"
    fi
    if [ -d "$PROJECT_ROOT/gridtokenx-trading/node_modules" ]; then
        run_in_terminal "Trading UI" "bun run dev --port 11001" "$PROJECT_ROOT/gridtokenx-trading"
    fi
    if [ -d "$PROJECT_ROOT/gridtokenx-explorer/node_modules" ]; then
        run_in_terminal "Explorer UI" "bun run dev --port 11002" "$PROJECT_ROOT/gridtokenx-explorer"
    fi
    if [ -d "$PROJECT_ROOT/gridtokenx-admin/node_modules" ]; then
        run_in_terminal "Admin UI" "bun run dev" "$PROJECT_ROOT/gridtokenx-admin"
    fi
}

# ============================================================================
# Command: START
# ============================================================================

cmd_start() {
    local skip_ui=false
    local skip_solana=false
    local docker_only=false
    local native_apps=false
    local docker_mode=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-ui)     skip_ui=true;     shift ;;
            --skip-solana) skip_solana=true;  shift ;;
            --docker-only) docker_only=true;  shift ;;
            --native-apps|--native|native) native_apps=true;  shift ;;
            --docker|docker) docker_mode=true; shift ;;
            *)             shift ;;
        esac
    done

    show_banner

    check_orbstack || {
        log_error "Cannot start services without OrbStack."
        exit 1
    }
    check_dependencies || true

    # Step 0: Kill ports first
    kill_ports

    # Step 1: Cleanup native service processes
    log_info "Cleaning up existing native processes..."
    solana_validator_stop
    pkill -f "api-services" 2>/dev/null || true
    pkill -f "gridtokenx-trading-service" 2>/dev/null || true
    pkill -f "gridtokenx-oracle-bridge" 2>/dev/null || true
    pkill -f "gridtokenx-iam-service" 2>/dev/null || true
    pkill -f "uvicorn" 2>/dev/null || true
    pkill -f "uv run start" 2>/dev/null || true
    pkill -f "bun run dev" 2>/dev/null || true
    sleep 2

    # Step 2: Core Docker Services
    start_core_services "$docker_mode"

    if [ "$docker_only" = true ]; then
        return 0
    fi

    # Step 3: Blockchain Services
    if [ "$skip_solana" = false ]; then
        start_blockchain_services

        echo ""
        log_info "Configuring environment..."
        cd "$ANCHOR_DIR"
        export ANCHOR_PROVIDER_URL="$RPC_URL"
        export ANCHOR_WALLET="$DEV_WALLET"

        local pda_config=$(npx tsx scripts/get_pdas.ts 2>/dev/null || echo "")
        local energy_mint=$(echo "$pda_config" | grep "ENERGY_TOKEN_MINT=" | cut -d'=' -f2)
        local currency_mint=$(echo "$pda_config" | grep "CURRENCY_TOKEN_MINT=" | cut -d'=' -f2)
        local registry_pda=$(echo "$pda_config" | grep "REGISTRY_PDA=" | cut -d'=' -f2)
        local trading_market_pda=$(echo "$pda_config" | grep "MARKET_PDA=" | cut -d'=' -f2)

        local REGISTRY_ID=$(grep -E "^registry =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
        local ENERGY_TOKEN_ID=$(grep -E "^energy_token =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
        local TRADING_ID=$(grep -E "^trading =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
        local ORACLE_ID=$(grep -E "^oracle =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
        local GOVERNANCE_ID=$(grep -E "^governance =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)

        local dev_pubkey=$(solana-keygen pubkey "$DEV_WALLET" 2>/dev/null || echo "")
        local collector_wallet=${dev_pubkey:-}

        propagate_program_ids \
            "$REGISTRY_ID" "$ENERGY_TOKEN_ID" "$TRADING_ID" "$ORACLE_ID" "$GOVERNANCE_ID" \
            "$energy_mint" "$currency_mint" "$registry_pda" "$trading_market_pda" \
            "$collector_wallet" "$collector_wallet" "$collector_wallet"

        log_success "Environment configured and propagated"
    fi

    # Step 4: Application Services
    if [ "$docker_mode" = false ]; then
        if [ "$native_apps" = true ]; then
            log_info "Starting application services as NATIVE BACKGROUND processes..."
            start_application_services "$skip_ui" "true"
        else
            log_info "Starting application services in default mode..."
            start_application_services "$skip_ui" "false"
        fi
    else
        log_info "Skipping native application services (Running in Docker mode)"
    fi

    echo $$ > "$PID_FILE"

    echo ""
    log_success "Development environment launched!"
    _show_start_summary "$skip_ui" "$native_apps" "$docker_mode"
}

_show_start_summary() {
    local skip_ui=$1
    local native_apps=$2
    local docker_mode=${3:-false}

    echo ""
    echo -e "${CYAN}API Services (Unified Port 4001):${NC}"
    echo "  • API Services:   http://localhost:4001/api/v1"
    echo "  • IAM Service:   http://localhost:4001/iam"
    echo "  • Trading API:   http://localhost:4001/trading"
    echo "  • Oracle Bridge: http://localhost:4001/oracle"
    echo "  • Solana RPC:    http://localhost:4001/solana"
    echo "  • Simulator API: http://localhost:4001/simulator"
    echo "  • Metrics:       http://localhost:4001/metrics-admin"
    echo "  • Grafana:       http://localhost:4001/grafana"
    echo ""
    echo -e "${CYAN}API Services (Direct Port 4000):${NC}"
    echo "  • API Services:   http://localhost:4000/api/v1"
    echo "  • Health:        http://localhost:4000/health"
    echo ""
    echo -e "${CYAN}Frontend UIs:${NC}"
    echo "  • Trading UI:    http://localhost:11001"
    echo "  • Explorer UI:   http://localhost:11002"
    echo "  • Simulator UI:  http://localhost:12011"
    echo ""
    echo -e "${CYAN}Service Logs:${NC}"
    echo "  • API Services:   $PROJECT_ROOT/scripts/logs/api-services.log"
    echo "  • IAM Service:   $PROJECT_ROOT/scripts/logs/iam.log"
    echo "  • Trading Svc:   $PROJECT_ROOT/scripts/logs/trading.log"
    echo "  • Oracle Bridge: $PROJECT_ROOT/scripts/logs/oracle-bridge.log"
    if [ "$skip_ui" = false ]; then
        echo "  • Trading UI:    $PROJECT_ROOT/scripts/logs/trading-ui.log"
        echo "  • Explorer UI:   $PROJECT_ROOT/scripts/logs/explorer-ui.log"
        echo "  • Simulator API: $PROJECT_ROOT/scripts/logs/simulator-api.log"
        echo "  • Simulator UI:  $PROJECT_ROOT/scripts/logs/simulator-ui.log"
    fi
    echo ""
    echo "Commands:"
    echo "  $0 stop         Stop all services"
    echo "  $0 status       Check service status"
    echo "  $0 register     Register admin user"
    if [ "$native_apps" = true ]; then
        echo ""
        echo -e "${YELLOW}Note: Services are running as background processes.${NC}"
        echo "  Use '$0 stop' to stop all services"
        echo "  Or manually kill processes using the log files above to find PIDs"
    fi
    echo ""
}
