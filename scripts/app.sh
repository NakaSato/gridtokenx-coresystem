#!/bin/bash
# GridTokenX - Unified Manager Script
export PATH="$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# GridTokenX Application Manager
# Unified script for starting, stopping, and managing the GridTokenX platform
#
# Usage: ./app.sh [command] [options]
#
# Commands:
#   start     - Start all services (Docker, Solana, API, Frontend)
#   stop      - Stop all services
#   restart   - Restart all services
#   doctor    - Check system dependencies and health
#   status    - Check service status
#   init      - Initialize blockchain and deploy programs
#   register  - Register admin user
#   seed      - Seed database with test users
#   logs      - View service logs
#
# Examples:
#   ./app.sh start                  # Start everything
#   ./app.sh start --skip-ui        # Start without frontend UIs
#   ./app.sh start --docker-only    # Start only Docker infrastructure
#   ./app.sh start --native-apps    # Docker infra + native app services (background)
#   ./app.sh stop                   # Stop all services
#   ./app.sh restart                # Restart all services
#   ./app.sh status                 # Check what's running
#   ./app.sh init                   # Just init blockchain
#   ./app.sh register               # Register admin user

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Project directories
# Resolve PROJECT_ROOT dynamically based on script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANCHOR_DIR="$PROJECT_ROOT/gridtokenx-anchor"
DEV_WALLET="$PROJECT_ROOT/infra/solana/dev-wallet.json"
PID_FILE="$PROJECT_ROOT/.gridtokenx.pid"

# Service ports
API_URL="http://localhost:4001"
RPC_URL="http://localhost:8899"
WS_URL="ws://localhost:8002"

# ============================================================================
# Helper Functions
# ============================================================================

check_dependencies() {
    local missing=()
    local deps=("docker" "solana" "anchor" "bun" "cargo" "uv" "jq" "curl")

    log_info "Checking system dependencies..."
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    # Check for rustup and toolchain
    if command -v rustup &> /dev/null; then
        local required_toolchain="1.89.0-sbpf-solana-v1.52"
        if ! rustup toolchain list | grep -q "$required_toolchain"; then
            log_warn "Required toolchain $required_toolchain not found. Attempting to install..."
            rustup toolchain install "$required_toolchain" || log_error "Failed to install toolchain $required_toolchain"
        fi
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_warn "Missing dependencies: ${missing[*]}"
        return 1
    fi
    log_success "All core dependencies found."
    return 0
}

# Detect Docker runtime (Docker Desktop or OrbStack)
detect_docker_runtime() {
    if docker info &>/dev/null; then
        local docker_info=$(docker info 2>/dev/null)
        if echo "$docker_info" | grep -qi "orbstack"; then
            DOCKER_RUNTIME="orbstack"
            return 0
        elif echo "$docker_info" | grep -qi "docker desktop"; then
            DOCKER_RUNTIME="docker-desktop"
            return 1
        else
            DOCKER_RUNTIME="unknown"
            return 1
        fi
    else
        DOCKER_RUNTIME="not-running"
        return 1
    fi
}

check_orbstack() {
    detect_docker_runtime || {
        if [ "$DOCKER_RUNTIME" = "not-running" ]; then
            log_warn "OrbStack is not running."
            return 1
        fi
        if [ "$DOCKER_RUNTIME" = "docker-desktop" ]; then
            log_error "Docker Desktop detected. GridTokenX now requires OrbStack."
            log_warn "Please migrate to OrbStack for better performance:"
            log_warn "1. Quit Docker Desktop"
            log_warn "2. Install OrbStack: brew install --cask orbstack"
            log_warn "3. Launch OrbStack (it will auto-migrate your data)"
            log_info "See: docs/ORBSTACK_MIGRATION.md"
        else
            log_error "OrbStack is required but not detected."
            log_info "Install: brew install --cask orbstack"
        fi
        return 1
    }
    log_success "OrbStack runtime detected ✓"
    return 0
}

cmd_doctor() {
    show_banner
    log_info "Running GridTokenX System Doctor..."
    echo ""

    # Check dependencies
    check_dependencies || log_warn "Please install missing dependencies to ensure all services can start."

    # Check OrbStack requirement
    check_orbstack || log_error "OrbStack is required but not properly configured."

    # Show OrbStack version if available
    if [ "$DOCKER_RUNTIME" = "orbstack" ] && command -v orb &>/dev/null; then
        log_success "OrbStack CLI found: $(orb --version 2>/dev/null || echo 'installed')"
    fi
    
    # Check Solana tools
    if command -v solana &>/dev/null; then
        local solana_ver=$(solana --version | head -n 1)
        log_success "Solana CLI found: $solana_ver"
    fi
    
    # Check Node.js/Bun
    if command -v bun &>/dev/null; then
        log_success "Bun found: $(bun --version)"
    fi
    
    echo ""
    log_info "Diagnostic complete!"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_banner() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        GridTokenX Application Manager              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_help() {
    show_banner
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  start     Start all services (Docker, Solana, API, Frontend)"
    echo "  stop      Stop all services"
    echo "  restart   Restart all services"
    echo "  status    Check service status"
    echo "  init      Initialize blockchain and deploy programs"
    echo "  register  Register admin user"
    echo "  seed      Seed database with test users (SQL)"
    echo "  logs      View service logs"
    echo "  doctor    Check system dependencies"
    echo ""
    echo "Options for 'start':"
    echo "  --skip-ui      Skip starting frontend UIs"
    echo "  --skip-solana  Skip starting Solana validator"
    echo "  --docker-only  Only start Docker services"
    echo "  --native-apps  Docker infra + native app services (background process)"
    echo ""
    echo "Examples:"
    echo "  $0 start              Start everything"
    echo "  $0 start --skip-ui    Start backend only"
    echo "  $0 start --docker-only    Start only Docker infrastructure"
    echo "  $0 start --native-apps    Docker + native background services"
    echo "  $0 stop               Stop all services"
    echo "  $0 status             Check what's running"
    echo ""
}

# Wait for service to be ready
wait_for_service() {
    local name=$1
    local url=$2
    local max_attempts=${3:-30}
    local interval=${4:-2}
    
    log_info "Waiting for $name to be ready..."
    for i in $(seq 1 $max_attempts); do
        if curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q "200"; then
            log_success "$name is ready!"
            return 0
        fi
        echo -ne "."
        sleep $interval
    done
    echo ""
    log_warn "$name did not respond within $(($max_attempts * $interval))s"
    return 1
}

wait_for_port() {
    local name=$1
    local port=$2
    local max_attempts=${3:-30}
    
    log_info "Waiting for $name (Port $port) to be open..."
    for i in $(seq 1 $max_attempts); do
        if nc -z localhost "$port" 2>/dev/null; then
            log_success "$name (Port $port) is open!"
            return 0
        fi
        echo -ne "."
        sleep 1
    done
    echo ""
    log_warn "$name did not respond on port $port"
    return 1
}

wait_for_postgres() {
    log_info "Waiting for PostgreSQL to be ready..."
    for i in {1..30}; do
        if docker exec gridtokenx-postgres pg_isready -U gridtokenx_user -d gridtokenx >/dev/null 2>&1; then
            log_success "PostgreSQL is ready!"
            return 0
        fi
        echo -ne "."
        sleep 1
    done
    echo ""
    log_error "PostgreSQL failed to start within 30 seconds"
    return 1
}

wait_for_redis() {
    log_info "Waiting for Redis to be ready..."
    for i in {1..30}; do
        if docker exec gridtokenx-redis redis-cli ping | grep -q PONG; then
            log_success "Redis is ready!"
            return 0
        fi
        echo -ne "."
        sleep 1
    done
    echo ""
    log_warn "Redis did not respond to PONG within 30 seconds"
    return 1
}

wait_for_solana() {
    log_info "Waiting for Solana validator to be ready..."
    for i in {1..30}; do
        if solana cluster-version --url $RPC_URL &>/dev/null; then
            log_success "Solana validator is ready!"
            return 0
        fi
        sleep 1
    done
    log_error "Solana validator failed to start"
    return 1
}

wait_for_port() {
    local name=$1
    local port=$2
    local timeout=${3:-30}
    
    log_info "Waiting for $name on port $port..."
    for i in $(seq 1 $timeout); do
        if nc -z 127.0.0.1 $port >/dev/null 2>&1; then
            log_success "$name is ready!"
            return 0
        fi
        echo -ne "."
        sleep 1
    done
    echo ""
    log_warn "$name did not respond on port $port within $timeout seconds"
    return 1
}

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

    # Portal (if it exists)
    if [ -d "$PROJECT_ROOT/gridtokenx-portal" ]; then
        local portal_env="$PROJECT_ROOT/gridtokenx-portal/.env"
        update_env_file "$portal_env" "NEXT_PUBLIC_TRADING_PROGRAM_ID" "$trading_id"
        update_env_file "$portal_env" "NEXT_PUBLIC_ENERGY_TOKEN_MINT" "$energy_mint"
        update_env_file "$portal_env" "NEXT_PUBLIC_SOLANA_RPC_URL" "$RPC_URL"
    fi

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

# Run command in background with logging
run_in_background() {
    local title="$1"
    local command="$2"
    local dir="$3"
    local log_file="$4"

    log_info "Starting $title in background..."
    mkdir -p "$(dirname "$log_file")"
    (cd "$dir" && nohup bash -c "$command" > "$log_file" 2>&1 &)
    log_success "$title started (logs: $log_file)"
}

# Run command in new Terminal window (macOS) - kept for compatibility
run_in_terminal() {
    local title="$1"
    local command="$2"
    local dir="$3"

    log_info "Starting $title..."
    (cd "$dir" && nohup bash -c "$command" > /dev/null 2>&1 &)
}

# ============================================================================
# Command: STOP
# ============================================================================

cmd_stop() {
    show_banner
    echo -e "${YELLOW}Stopping GridTokenX services...${NC}"
    echo ""

    # Stop APISIX + Envoy Gateways
    docker stop gridtokenx-apisix 2>/dev/null && log_success "APISIX stopped" || log_warn "APISIX was not running"
    docker stop gridtokenx-envoy 2>/dev/null && log_success "Envoy stopped" || log_warn "Envoy was not running"

    # Stop IAM Service
    pkill -f "gridtokenx-iam-service" 2>/dev/null && log_success "IAM Service stopped" || log_warn "IAM Service was not running"
    
    # Stop Trading Service
    pkill -f "gridtokenx-trading-service" 2>/dev/null && log_success "Trading Service stopped" || log_warn "Trading Service was not running"
    
    # Stop Oracle Bridge
    pkill -f "gridtokenx-oracle-bridge" 2>/dev/null && log_success "Oracle Bridge stopped" || log_warn "Oracle Bridge was not running"
    
    # Stop Frontend UIs
    pkill -f "bun run dev" 2>/dev/null || true
    pkill -f "vite" 2>/dev/null || true
    
    # Stop Simulator
    pkill -f "uvicorn" 2>/dev/null || true
    pkill -f "uv run start" 2>/dev/null && log_success "Simulator stopped" || true
    
    # Stop Solana
    pkill -f "solana-test-validator" 2>/dev/null && log_success "Solana validator stopped" || log_warn "Solana validator was not running"
    
    # Full stop including Docker
    if [ "$1" == "--all" ]; then
        echo ""
        log_info "Stopping Docker services..."
        cd "$PROJECT_ROOT"
        docker-compose down 2>/dev/null && log_success "OrbStack services stopped" || log_warn "OrbStack services were not running"
    fi
    
    # Remove PID file
    rm -f "$PID_FILE"
    
    echo ""
    log_success "All services stopped!"
    
    if [ "$1" != "--all" ]; then
        echo ""
        log_warn "Note: Docker services (PostgreSQL, Redis) are still running."
        echo "Use '$0 stop --all' to stop everything including Docker."
    fi
}

# ============================================================================
# Command: STATUS
# ============================================================================

cmd_status() {
    show_banner
    
    # Detect and display Docker runtime
    detect_docker_runtime || true
    if [ "$DOCKER_RUNTIME" = "orbstack" ]; then
        echo -e "${GREEN}⚡️ OrbStack Runtime (primary)${NC}"
    elif [ "$DOCKER_RUNTIME" = "docker-desktop" ]; then
        echo -e "${YELLOW}🐳 Docker Desktop (deprecated - please migrate to OrbStack)${NC}"
    elif [ "$DOCKER_RUNTIME" = "not-running" ]; then
        echo -e "${RED}✗ No Docker runtime detected${NC}"
    fi
    echo ""
    
    echo "Service Status:"
    echo "==============="
    echo ""
    
    local services=(
        "PostgreSQL:docker:gridtokenx-postgres"
        "Redis:docker:gridtokenx-redis"
        "APISIX:docker:gridtokenx-apisix"
        "Envoy:docker:gridtokenx-envoy"
        "Prometheus:docker:gridtokenx-prometheus"
        "Grafana:docker:gridtokenx-grafana"
        "Loki:docker:gridtokenx-loki"
        "Tempo:docker:gridtokenx-tempo"
        "OTEL Collector:docker:gridtokenx-otel-collector"
        "IAM Service:process:gridtokenx-iam-service"
        "Trading Service:process:trading-service"
        "Oracle Bridge:process:oracle-service"
        "Noti Service:process:noti-server"
        "Chain Bridge:process:gridtokenx-chain-bridge"
        "Solana Validator:process:solana-test-validator"
        "Simulator API:process:uv.run.start"
        "Trading UI:process:bun.*gridtokenx-trading"
        "Explorer UI:process:bun.*gridtokenx-explorer"
        "App Portal:process:bun.*gridtokenx-portal"
        "Simulator UI:process:bun.*dev.*12011"
        "Agent Trade:docker:gridtokenx-agent-trade"
    )
    
    printf "%-25s %-15s %-10s\n" "Service" "Type" "Status"
    printf "%-25s %-15s %-10s\n" "-------" "----" "------"
    
    for service in "${services[@]}"; do
        IFS=':' read -r name type pattern <<< "$service"
        
        local status_icon="${RED}✗${NC}"
        local status_text="${RED}Stopped${NC}"
        
        if [ "$type" == "docker" ]; then
            if docker ps --format '{{.Names}}' | grep -q "^${pattern}$"; then
                status_icon="${GREEN}✓${NC}"
                status_text="${GREEN}Running${NC}"
            fi
        else
            if pgrep -f "$pattern" > /dev/null 2>&1; then
                status_icon="${GREEN}✓${NC}"
                status_text="${GREEN}Running${NC}"
            fi
        fi
        
        printf "%b %-23s %-15s %b\n" "$status_icon" "$name" "$type" "$status_text"
    done
    
    echo ""
    
    # Check endpoints
    echo "Endpoint Status:"
    echo "================"
    
    if curl -s "$RPC_URL/health" > /dev/null 2>&1; then
        echo -e "Solana RPC ($RPC_URL): ${GREEN}✓ Ready${NC}"
    else
        echo -e "Solana RPC ($RPC_URL): ${RED}✗ Unreachable${NC}"
    fi
    
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/metrics" 2>/dev/null || echo "000")
    if [ "$http_code" == "200" ]; then
        echo -e "Platform Gateway ($API_URL): ${GREEN}✓ Ready${NC}"
    else
        echo -e "Platform Gateway ($API_URL): ${RED}✗ Unreachable${NC} (HTTP $http_code)"
    fi

    if curl -s "http://localhost:6002/api/health" > /dev/null 2>&1; then
        echo -e "Grafana (http://localhost:6002): ${GREEN}✓ Ready${NC}"
    else
        echo -e "Grafana (http://localhost:6002): ${RED}✗ Unreachable${NC}"
    fi

    if curl -s "http://localhost:6003/ready" > /dev/null 2>&1; then
        echo -e "Loki (http://localhost:6003): ${GREEN}✓ Ready${NC}"
    else
        echo -e "Loki (http://localhost:6003): ${RED}✗ Unreachable${NC}"
    fi

    if curl -s "http://localhost:6001/-/healthy" > /dev/null 2>&1; then
        echo -e "Prometheus (http://localhost:6001): ${GREEN}✓ Ready${NC}"
    else
        echo -e "Prometheus (http://localhost:6001): ${RED}✗ Unreachable${NC}"
    fi

    echo ""
}

# ============================================================================
# Command: INIT (Blockchain)
# ============================================================================

cmd_init() {
    show_banner
    log_info "Initializing Blockchain..."
    echo ""
    
    # Check dependencies
    if ! command -v anchor &> /dev/null; then
        log_error "anchor CLI is not installed. See https://www.anchor-lang.com/docs/installation"
    fi
    
    if ! command -v solana &> /dev/null; then
        log_error "solana CLI is not installed"
    fi
    
    # Build programs
    log_info "Building Anchor Programs..."
    cd "$ANCHOR_DIR"
    export PATH="$HOME/.cargo/bin:$PATH"
    anchor build
    
    # Check validator
    if ! curl -s "$RPC_URL/health" > /dev/null 2>&1; then
        log_warn "Solana validator not running. Starting it..."
        solana-test-validator --reset --ledger "$PROJECT_ROOT/test-ledger" > "$PROJECT_ROOT/solana.log" 2>&1 &
        wait_for_solana
    fi
    
    # Deploy programs
    log_info "Deploying Programs (Using existing keypairs for consistent IDs)..."
    
    deploy_program() {
        local NAME=$1
        local ID=$2
        
        log_info "Deploying $NAME ($ID)..."
        # Use existing keypair if available to keep Program ID
        local KEYPAIR="$ANCHOR_DIR/target/deploy/${NAME}-keypair.json"
        
        solana program deploy \
            --program-id "$KEYPAIR" \
            "$ANCHOR_DIR/target/deploy/${NAME}.so" \
            --url "$RPC_URL" 2>/dev/null || log_warn "Deployment may have failed or already exists (ID: $ID)"
    }
    
    # Program IDs from Anchor.toml
    local REGISTRY_ID="C8RT8L5pZCVDrf9v94CNNk3XPBKZU5p4o4aPnAVQGiTu"
    local ENERGY_TOKEN_ID="n52aKuZwUeZAocpWqRZAJR4xFhQqAvaRE7Xepy2JBGk"
    local TRADING_ID="69dGpKu9a8EZiZ7orgfTH6CoGj9DeQHHkHBF2exSr8na"
    local ORACLE_ID="JDUVXMkeGi4oxLp8njBaGScAFaVBBg7iGoiqcY1LxKop"
    local GOVERNANCE_ID="DamT9e1VqbA5nSyFZHExKwQu6qs4L5FW6dirWCK8YLd4"

    deploy_program "registry" "$REGISTRY_ID"
    deploy_program "energy_token" "$ENERGY_TOKEN_ID"
    deploy_program "trading" "$TRADING_ID"
    deploy_program "oracle" "$ORACLE_ID"
    deploy_program "governance" "$GOVERNANCE_ID"
    
    # Extract metadata for propagation
    log_info "Bootstrapping on-chain accounts..."
    cd "$ANCHOR_DIR"
    export ANCHOR_PROVIDER_URL="$RPC_URL"
    export ANCHOR_WALLET="$DEV_WALLET"
    
    # Wait for validator
    sleep 5
    
    # Extract dev-wallet pubkey to authorize it in the oracle
    local dev_pubkey=$(solana-keygen pubkey "$DEV_WALLET" 2>/dev/null || echo "")
    if [ -n "$dev_pubkey" ]; then
        log_info "Authorizing dev-wallet ($dev_pubkey) as Oracle API Gateway..."
        ORACLE_API_GATEWAY="$dev_pubkey" npx ts-node scripts/bootstrap.ts || log_warn "Bootstrap script failed, but continuing..."
    else
        npx ts-node scripts/bootstrap.ts || log_warn "Bootstrap script failed, but continuing..."
    fi
    
    log_info "Extracting PDAs and Mint addresses..."
    local pda_config=$(npx ts-node scripts/get_pdas.ts 2>/dev/null || echo "")
    local energy_mint=$(echo "$pda_config" | grep "ENERGY_TOKEN_MINT=" | cut -d'=' -f2)
    local currency_mint=$(echo "$pda_config" | grep "CURRENCY_TOKEN_MINT=" | cut -d'=' -f2)
    local registry_pda=$(echo "$pda_config" | grep "REGISTRY_PDA=" | cut -d'=' -f2)
    local trading_market_pda=$(echo "$pda_config" | grep "TRADING_MARKET_PDA=" | cut -d'=' -f2)

    # Propagate
    propagate_program_ids \
        "$REGISTRY_ID" \
        "$ENERGY_TOKEN_ID" \
        "$TRADING_ID" \
        "$ORACLE_ID" \
        "$GOVERNANCE_ID" \
        "${energy_mint:-FYoHgS599B9ZmCeyDpoTVYTR2K165py1HpyC1QkxqFzN}" \
        "$currency_mint" \
        "$registry_pda" \
        "$trading_market_pda" \
        "C8RT8L5pZCVDrf9v94CNNk3XPBKZU5p4o4aPnAVQGiTu" \
        "C8RT8L5pZCVDrf9v94CNNk3XPBKZU5p4o4aPnAVQGiTu" \
        "C8RT8L5pZCVDrf9v94CNNk3XPBKZU5p4o4aPnAVQGiTu"

    log_success "Blockchain initialization complete!"
}

# ============================================================================
# Command: REGISTER (Admin)
# ============================================================================

cmd_register() {
    show_banner
    
    local email="${1:-admin_$(date +%s)@example.com}"
    local username="${2:-admin_$(date +%s)}"
    local password="${3:-P@ssw0rd123!}"
    local first_name="${4:-Admin}"
    local last_name="${5:-User}"
    
    log_info "Registering admin user..."
    echo "  Email: $email"
    echo "  Username: $username"
    
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
    fi
    
    local resp=$(curl -s -X POST "$API_URL/api/v1/users" \
        -H "Content-Type: application/json" \
        -d "{
            \"email\": \"$email\",
            \"password\": \"$password\",
            \"username\": \"$username\",
            \"first_name\": \"$first_name\",
            \"last_name\": \"$last_name\"
        }")
    
    local token=$(echo "$resp" | jq -r '.data.auth.access_token // .auth.access_token // empty')
    
    # If no token in registration response, try to login automatically
    if [ -z "$token" ] || [ "$token" == "null" ]; then
        log_info "Registration successful, attempting automatic login to get token..."
        resp=$(curl -s -X POST "$API_URL/api/v1/auth/token" \
            -H "Content-Type: application/json" \
            -d "{
                \"username\": \"$email\",
                \"password\": \"$password\"
            }")
        token=$(echo "$resp" | jq -r '.access_token // .data.auth.access_token // .auth.access_token // empty')
    fi

    if [ -n "$token" ] && [ "$token" != "null" ]; then
        echo "$token" > "$PROJECT_ROOT/.admin_token"
        log_success "Admin registered and authenticated successfully!"
        log_info "Token saved to .admin_token"
    else
        log_error "Failed to acquire admin token. Response: $resp"
    fi
}

# ============================================================================
# Command: SEED (Database)
# ============================================================================

cmd_seed() {
    show_banner
    log_info "Seeding database with test users..."
    
    if [ -f "$PROJECT_ROOT/scripts/seed_1000_users.sql" ]; then
        docker exec -i gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx < "$PROJECT_ROOT/scripts/seed_1000_users.sql"
        log_success "Database seeded with test users!"
    else
        log_warn "seed_1000_users.sql not found, skipping"
    fi
}

# ============================================================================
# Command: LOGS
# ============================================================================

cmd_logs() {
    local service="$1"
    
    case "$service" in
        api|gateway)
            log_info "API Gateway logs:"
            ;;
        solana|validator)
            tail -f "$PROJECT_ROOT/solana.log" 2>/dev/null || log_error "No solana.log found"
            ;;
        postgres|db)
            docker logs -f gridtokenx-postgres
            ;;
        redis)
            docker logs -f gridtokenx-redis
            ;;
        *)
            show_banner
            echo "View logs for a service"
            echo ""
            echo "Usage: $0 logs [service]"
            echo ""
            echo "Services: api, solana, postgres, redis"
            echo ""
            ;;
    esac
}

# ============================================================================
# Modular Start Functions
# ============================================================================

start_core_services() {
    log_info "Starting Core OrbStack services..."
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running."
    fi

    cd "$PROJECT_ROOT"
    docker-compose up -d postgres redis mailpit apisix envoy rabbitmq kafka-cmd
    # Ensure Docker versions of application services are stopped to prevent port conflicts (native execution preferred)
    docker stop gridtokenx-trading-service gridtokenx-api-services gridtokenx-iam-service gridtokenx-oracle-bridge >/dev/null 2>&1 || true
    wait_for_postgres
    wait_for_redis
    log_success "Core services ready"
}

start_blockchain_services() {
    echo ""
    log_info "Starting Solana test validator..."
    mkdir -p "$PROJECT_ROOT/scripts/logs"
    solana-test-validator --reset --ledger "$PROJECT_ROOT/test-ledger" > "$PROJECT_ROOT/scripts/logs/validator.log" 2>&1 &
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

    # Ensure native services use localhost for OTEL Collector (instead of container name)
    export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4317"
    export OTEL_ENABLED="true"

    # Default Environment Variables for Native Execution (if not set in .env)
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
    export RABBITMQ_URL=${RABBITMQ_URL:-"amqp://gridtokenx:rabbitmq_secret_2025@localhost:9030"}
    
    # Trading specific
    export ENERGY_TOKEN_MINT=${ENERGY_TOKEN_MINT:-"GpGDVgksF2ivMv3XXR4VZDXRmW9G6agA2AGkKUBQRzk6"}
    export CURRENCY_TOKEN_MINT=${CURRENCY_TOKEN_MINT:-"8BGFtQLRaY9Nh5BGUwjJvdeXEsscCgJAi5zTgALk1Vg5"}
    export FEE_COLLECTOR_WALLET=${FEE_COLLECTOR_WALLET:-"$PROJECT_ROOT/infra/solana/dev-wallet.json"}

    # Noti specific (uses APP prefix)
    export APP__PORT=${APP__PORT:-"5050"}
    export APP__DATABASE_URL=${APP__DATABASE_URL:-"postgresql://gridtokenx_user:gridtokenx_password@localhost:7001/gridtokenx_noti"}
    export APP__KAFKA_BROKERS=${APP__KAFKA_BROKERS:-"localhost:29001"}
    export APP__REDIS_URL=${APP__REDIS_URL:-"redis://localhost:7010"}
    export APP__RABBITMQ_URL=${APP__RABBITMQ_URL:-"amqp://gridtokenx:rabbitmq_secret_2025@localhost:9030"}
    export APP__LOG_LEVEL=${APP__LOG_LEVEL:-"info"}

    if [ "$native_mode" = true ]; then
        # Native background mode with proper logging
        log_info "Starting services as native background processes..."

        # 0. Chain Bridge (Blockchain Connector)
        run_in_background "Chain Bridge" \
            "SOLANA_RPC_URL=$SOLANA_RPC_URL $PROJECT_ROOT/gridtokenx-chain-bridge/target/debug/gridtokenx-chain-bridge" \
            "$PROJECT_ROOT" \
            "$PROJECT_ROOT/scripts/logs/chain-bridge.log"
        wait_for_port "Chain Bridge" 5040 30

        # 1. IAM Service (Identity & Access Management) - Required by everything
        run_in_background "IAM Service" \
            "DATABASE_URL=$IAM_DATABASE_URL REDIS_URL=$REDIS_URL IAM_PORT=4010 $PROJECT_ROOT/gridtokenx-iam-service/target/debug/gridtokenx-iam-service" \
            "$PROJECT_ROOT" \
            "$PROJECT_ROOT/scripts/logs/iam.log"
        wait_for_port "IAM gRPC" 5010 30

        # 2. Trading Service (Matching & Settlement) - Required by API Gateway for order submission
        run_in_background "Trading Service" \
            "DATABASE_URL=$TRADING_DATABASE_URL REDIS_URL=$REDIS_URL SOLANA_RPC_URL=$SOLANA_RPC_URL SOLANA_WS_URL=$SOLANA_WS_URL RUST_LOG=info ENABLE_SETTLEMENT_PROCESSOR=true $PROJECT_ROOT/gridtokenx-trading-service/target/debug/trading-service" \
            "$PROJECT_ROOT" \
            "$PROJECT_ROOT/scripts/logs/trading.log"
        # wait_for_port "Trading gRPC" 5020 60
        
        # 3. Oracle Bridge (Smart Meter to Solana Synchronization)
        run_in_background "Oracle Bridge" \
            "IAM_SERVICE_URL=http://127.0.0.1:4010 GRIDTOKENX_API_KEYS=\"engineering-department-api-key-2025\" RUST_LOG=info $PROJECT_ROOT/gridtokenx-oracle-bridge/target/debug/oracle-service" \
            "$PROJECT_ROOT" \
            "$PROJECT_ROOT/scripts/logs/oracle-bridge.log"
        wait_for_port "Oracle Bridge" 4030 30

        # 4. Noti Service (Notifications & Events)
        run_in_background "Noti Service" \
            "DATABASE_URL=$NOTI_DATABASE_URL REDIS_URL=$REDIS_URL RUST_LOG=info $PROJECT_ROOT/gridtokenx-noti-service/target/debug/noti-server" \
            "$PROJECT_ROOT" \
            "$PROJECT_ROOT/scripts/logs/noti.log"
        wait_for_port "Noti gRPC" 5050 30

        # Wait for APISIX proxy
        wait_for_service "APISIX" "http://localhost:4001/health" 60 2

        if [ "$skip_ui" = false ]; then
            echo ""
            log_info "Starting frontend UIs as background processes..."

            # Simulator
            if [ -f "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/backend/pyproject.toml" ]; then
                run_in_background "Simulator API" \
                    "PORT=12010 uv run start" \
                    "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/backend" \
                    "$PROJECT_ROOT/scripts/logs/simulator-api.log"
            fi

            # Trading UI
            if [ -d "$PROJECT_ROOT/gridtokenx-trading/node_modules" ]; then
                run_in_background "Trading UI" \
                    "bun run dev" \
                    "$PROJECT_ROOT/gridtokenx-trading" \
                    "$PROJECT_ROOT/scripts/logs/trading-ui.log"
            fi

            # Explorer UI
            if [ -d "$PROJECT_ROOT/gridtokenx-explorer/node_modules" ]; then
                run_in_background "Explorer UI" \
                    "bun run dev --port 11002" \
                    "$PROJECT_ROOT/gridtokenx-explorer" \
                    "$PROJECT_ROOT/scripts/logs/explorer-ui.log"
            fi

            # App Portal
            if [ -d "$PROJECT_ROOT/gridtokenx-portal/node_modules" ]; then
                run_in_background "App Portal" \
                    "bun run dev --port 11003" \
                    "$PROJECT_ROOT/gridtokenx-portal" \
                    "$PROJECT_ROOT/scripts/logs/portal.log"
            fi

            # Simulator UI
            if [ -d "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/frontend/node_modules" ]; then
                run_in_background "Simulator UI" \
                    "bun run dev --port 12011" \
                    "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/frontend" \
                    "$PROJECT_ROOT/scripts/logs/simulator-ui.log"
            fi

            # Admin UI
            if [ -d "$PROJECT_ROOT/gridtokenx-admin/node_modules" ]; then
                run_in_background "Admin UI" \
                    "bun run dev" \
                    "$PROJECT_ROOT/gridtokenx-admin" \
                    "$PROJECT_ROOT/scripts/logs/admin-ui.log"
            fi
        fi
    else
        # Original terminal mode (for backward compatibility)
        # 1. IAM Service (Identity & Access Management) - Required by everything
        run_in_terminal "IAM Service" "IAM_PORT=4010 $PROJECT_ROOT/target/debug/gridtokenx-iam-service > $PROJECT_ROOT/scripts/logs/iam.log 2>&1" "$PROJECT_ROOT"
        wait_for_port "IAM gRPC" 5010 30

        # 2. Trading Service (Matching & Settlement) - Required by API Gateway for order submission
        run_in_terminal "Trading Service" "RUST_LOG=info ENABLE_SETTLEMENT_PROCESSOR=true $PROJECT_ROOT/target/debug/gridtokenx-trading-service > $PROJECT_ROOT/scripts/logs/trading.log 2>&1" "$PROJECT_ROOT"
        wait_for_port "Trading gRPC" 5020 60

        # 3. Oracle Bridge (Smart Meter to Solana Synchronization)
        run_in_terminal "Oracle Bridge" "IAM_SERVICE_URL=http://127.0.0.1:4010 GRIDTOKENX_API_KEYS=\"engineering-department-api-key-2025\" RUST_LOG=info $PROJECT_ROOT/target/debug/gridtokenx-oracle-bridge > $PROJECT_ROOT/scripts/logs/oracle-bridge.log 2>&1" "$PROJECT_ROOT"

        # Wait for the APISIX proxy (now on 4001)
        wait_for_service "APISIX" "http://localhost:4001/health" 60 2

        if [ "$skip_ui" = false ]; then
            echo ""
            log_info "Starting frontend UIs..."

            # Simulator
            if [ -d "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/frontend/node_modules" ]; then
                run_in_terminal "Simulator UI" "bun run dev --port 12011" "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/frontend"
            fi

            if [ -f "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/backend/pyproject.toml" ]; then
                run_in_terminal "Simulator API" "PORT=12010 uv run start" "$PROJECT_ROOT/gridtokenx-smartmeter-simulator/backend"
            fi

            # Trading UI
            if [ -d "$PROJECT_ROOT/gridtokenx-trading/node_modules" ]; then
                run_in_terminal "Trading UI" "bun run dev" "$PROJECT_ROOT/gridtokenx-trading"
            fi

            # Explorer UI
            if [ -d "$PROJECT_ROOT/gridtokenx-explorer/node_modules" ]; then
                run_in_terminal "Explorer UI" "bun run dev --port 11002" "$PROJECT_ROOT/gridtokenx-explorer"
            fi

            # App Portal
            if [ -d "$PROJECT_ROOT/gridtokenx-portal/node_modules" ]; then
                run_in_terminal "App Portal" "bun run dev --port 11003" "$PROJECT_ROOT/gridtokenx-portal"
            fi

            # Admin UI
            if [ -d "$PROJECT_ROOT/gridtokenx-admin/node_modules" ]; then
                run_in_terminal "Admin UI" "bun run dev" "$PROJECT_ROOT/gridtokenx-admin"
            fi
        fi
    fi
}

kill_ports() {
    local ports=(4000 4001 4002 4010 4020 4030 5010 5020 5030 5040 6001 6002 6003 6004 6005 6006 7001 7002 7010 7011 7020 7030 8001 8002 9001 9002 9003 9030 9031 10010 10020 10030 10040 10100 10110 10120 10130 10200 10210 10220 10230 11001 11002 11003 12010 12011 13001 13060)
    log_info "Clearing ports: ${ports[*]}..."
    for port in "${ports[@]}"; do
        local pids=$(lsof -ti:"$port" 2>/dev/null)
        if [ -n "$pids" ]; then
            for pid in $pids; do
                local comm=$(ps -p "$pid" -o comm= 2>/dev/null)
                local cmdline=$(ps -p "$pid" -o args= 2>/dev/null)
                # Skip Docker/OrbStack-managed processes
                if [[ "$comm" == *"com.docker"* ]] || [[ "$comm" == *"docker-proxy"* ]] || \
                   [[ "$comm" == *"OrbStack Helper"* ]] || [[ "$comm" == *"orbstack"* ]] || \
                   [[ "$cmdline" == *"orbstack"* ]]; then
                    log_info "Port $port is managed by Docker runtime ($comm), skipping."
                    continue
                fi
                
                log_warn "Killing local process $pid on port $port ($comm)..."
                kill -9 "$pid" 2>/dev/null || true
            done
        fi
    done
}

# ============================================================================
# Command: START
# ============================================================================

cmd_start() {
    local skip_ui=false
    local skip_solana=false
    local docker_only=false
    local native_apps=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-ui)
                skip_ui=true
                shift
                ;;
            --skip-solana)
                skip_solana=true
                shift
                ;;
            --docker-only)
                docker_only=true
                shift
                ;;
            --native-apps)
                native_apps=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    show_banner

    # Pre-flight: Check OrbStack requirement
    check_orbstack || {
        log_error "Cannot start services without OrbStack."
        exit 1
    }

    check_dependencies || true

    # Step 0: Kill ports first
    kill_ports

    # Step 1: Cleanup native service processes (run via direct command)
    log_info "Cleaning up existing native processes..."
    pkill -f "solana-test-validator" 2>/dev/null || true
    pkill -f "api-services" 2>/dev/null || true
    pkill -f "gridtokenx-trading-service" 2>/dev/null || true
    pkill -f "gridtokenx-oracle-bridge" 2>/dev/null || true
    pkill -f "gridtokenx-iam-service" 2>/dev/null || true
    pkill -f "uvicorn" 2>/dev/null || true
    pkill -f "uv run start" 2>/dev/null || true
    pkill -f "bun run dev" 2>/dev/null || true
    pkill -f "agent-trade" 2>/dev/null || true
    sleep 2

    # Step 2: Core Docker Services
    start_core_services

    if [ "$docker_only" = true ]; then
        return 0
    fi

    # Step 3: Blockchain Services
    if [ "$skip_solana" = false ]; then
        start_blockchain_services

        # Step 4: Anchor Configuration
        echo ""
        log_info "Configuring environment..."
        cd "$ANCHOR_DIR"
        export ANCHOR_PROVIDER_URL="$RPC_URL"
        export ANCHOR_WALLET="$DEV_WALLET"

        local pda_config=$(npx ts-node scripts/get_pdas.ts 2>/dev/null || echo "")
        local energy_mint=$(echo "$pda_config" | grep "ENERGY_TOKEN_MINT=" | cut -d'=' -f2)
        local currency_mint=$(echo "$pda_config" | grep "CURRENCY_TOKEN_MINT=" | cut -d'=' -f2)
        local registry_pda=$(echo "$pda_config" | grep "REGISTRY_PDA=" | cut -d'=' -f2)
        local trading_market_pda=$(echo "$pda_config" | grep "TRADING_MARKET_PDA=" | cut -d'=' -f2)

        # Program IDs from Anchor.toml
        local REGISTRY_ID="C8RT8L5pZCVDrf9v94CNNk3XPBKZU5p4o4aPnAVQGiTu"
        local ENERGY_TOKEN_ID="n52aKuZwUeZAocpWqRZAJR4xFhQqAvaRE7Xepy2JBGk"
        local TRADING_ID="69dGpKu9a8EZiZ7orgfTH6CoGj9DeQHHkHBF2exSr8na"
        local ORACLE_ID="JDUVXMkeGi4oxLp8njBaGScAFaVBBg7iGoiqcY1LxKop"
        local GOVERNANCE_ID="DamT9e1VqbA5nSyFZHExKwQu6qs4L5FW6dirWCK8YLd4"

        propagate_program_ids \
            "$REGISTRY_ID" \
            "$ENERGY_TOKEN_ID" \
            "$TRADING_ID" \
            "$ORACLE_ID" \
            "$GOVERNANCE_ID" \
            "${energy_mint:-FYoHgS599B9ZmCeyDpoTVYTR2K165py1HpyC1QkxqFzN}" \
            "$currency_mint" \
            "$registry_pda" \
            "$trading_market_pda" \
            "C8RT8L5pZCVDrf9v94CNNk3XPBKZU5p4o4aPnAVQGiTu" \
            "C8RT8L5pZCVDrf9v94CNNk3XPBKZU5p4o4aPnAVQGiTu" \
            "C8RT8L5pZCVDrf9v94CNNk3XPBKZU5p4o4aPnAVQGiTu"

        log_success "Environment configured and propagated"
    fi

    # Step 5: Application Services
    if [ "$native_apps" = true ]; then
        log_info "Starting application services as NATIVE BACKGROUND processes..."
        start_application_services "$skip_ui" "true"
    else
        log_info "Starting application services in default mode..."
        start_application_services "$skip_ui" "false"
    fi

    # Save PIDs for background processes
    echo $$ > "$PID_FILE"

    echo ""
    log_success "Development environment launched!"
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
    echo "  • App Portal:    http://localhost:11003"
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
        echo "  • Portal:        $PROJECT_ROOT/scripts/logs/portal.log"
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

# ============================================================================
# Main
# ============================================================================

main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        start)
            cmd_start "$@"
            ;;
        stop)
            cmd_stop "$@"
            ;;
        restart)
            local fast_restart=false
            if [[ "$1" == "--fast" ]]; then
                fast_restart=true
                shift
            fi
            
            cmd_stop
            
            if [ "$fast_restart" = false ]; then
                echo ""
                log_info "Cleaning up database, solana ledger, and cache data..."
                cd "$PROJECT_ROOT"
                docker-compose down -v 2>/dev/null || true
                rm -rf "$PROJECT_ROOT/test-ledger"
                rm -rf "$PROJECT_ROOT/scripts/logs"
                rm -f "$PROJECT_ROOT/.admin_token"
                log_success "Cleanup complete"
            fi
            
            sleep 2
            cmd_start "$@"
            ;;
        doctor)
            cmd_doctor
            ;;
        status)
            cmd_status
            ;;
        init)
            cmd_init
            ;;
        register)
            cmd_register "$@"
            ;;
        seed)
            cmd_seed
            ;;
        logs)
            cmd_logs "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
