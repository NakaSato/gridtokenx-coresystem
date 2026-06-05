#!/bin/bash
# GridTokenX - Common utilities (colors, logging, banner, help)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Project directories
# Resolve PROJECT_ROOT dynamically based on script location
# common.sh lives in scripts/lib/, so go up two levels to reach project root
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$_LIB_DIR/../.." && pwd)"

# Load Environment
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a; source "$PROJECT_ROOT/.env"; set +a
fi
RPC_URL=${SOLANA_RPC_URL:-${RPC_URL:-"http://localhost:8899"}}

ANCHOR_DIR="$PROJECT_ROOT/gridtokenx-anchor"
DEV_WALLET="$PROJECT_ROOT/infra/solana/dev-wallet.json"
PID_FILE="$PROJECT_ROOT/.gridtokenx.pid"


# --- Solana Validator Helpers ---

solana_validator_start() {
    local ledger_dir="${1:-$PROJECT_ROOT/test-ledger}"
    local log_file="${2:-$PROJECT_ROOT/scripts/logs/validator.log}"
    local extra_args="${3:-}"

    log_info "Starting Solana test validator..."
    
    # Apple Silicon (Darwin/ARM64) optimizations
    if [ "$(uname)" == "Darwin" ] && [ "$(uname -m)" == "arm64" ]; then
        log_info "Applying Apple Silicon (M2) optimizations..."
        ulimit -n 65536
    fi
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$log_file")"
    
    # Assemble final command
    # Added --rpc-port 8899 explicitly
    if [ -z "$extra_args" ]; then
        solana-test-validator --reset --limit-ledger-size 10000 --ledger "$ledger_dir" --rpc-port 8899 > "$log_file" 2>&1 &
    else
        solana-test-validator --reset --limit-ledger-size 10000 --ledger "$ledger_dir" --rpc-port 8899 $extra_args > "$log_file" 2>&1 &
    fi
}

solana_validator_stop() {
    log_info "Stopping Solana test validator..."
    pkill -f "solana-test-validator" 2>/dev/null && log_success "Solana validator stopped" || log_warn "Solana validator was not running"
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
    echo "  start     Start all services (Default: Terminal mode)"
    echo "  native    Start all services in Native Background mode"
    echo "  docker    Start all services in Docker mode"
    echo "  stop      Stop all services"
    echo "  restart   Restart all services"
    echo "  status    Check service status"
    echo "  init      Initialize blockchain and deploy programs"
    echo "  register  Register admin user"
    echo "  seed      Seed database with test users (SQL)"
    echo "  logs      View service logs"
    echo "  solana    Manage local solana test validator (start/stop)"
    echo "  doctor    Check system dependencies"
    echo ""
    echo "Options for 'start', 'native', 'docker':"
    echo "  --skip-ui      Skip starting frontend UIs"
    echo "  --skip-solana  Skip starting Solana validator"
    echo "  --docker-only  Only start Docker services (Infrastructure only)"
    echo ""
    echo "Examples:"
    echo "  $0 start              Start everything in Terminal mode"
    echo "  $0 native             Start native background services"
    echo "  $0 docker             Start everything in Docker"
    echo "  $0 stop               Stop all services"
    echo "  $0 status             Check what's running"
    echo ""
}
