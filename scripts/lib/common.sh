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
ANCHOR_DIR="$PROJECT_ROOT/gridtokenx-anchor"
DEV_WALLET="$PROJECT_ROOT/infra/solana/dev-wallet.json"
PID_FILE="$PROJECT_ROOT/.gridtokenx.pid"

# Service ports
API_URL="http://localhost:4001"
RPC_URL="http://localhost:8899"
WS_URL="ws://localhost:8002"

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
