#!/bin/bash
# GridTokenX - Unified Manager Script
export PATH="$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# GridTokenX Application Manager
# Unified script for starting, stopping, and managing the GridTokenX platform
#
# Usage: ./app.sh [command] [options]
#
# Commands:
#   start     - Start all services (Default: Terminal mode)
#   native    - Start all services in Native Background mode
#   docker    - Start all services in Docker mode
#   stop      - Stop all services
#   restart   - Restart all services
#   doctor    - Check system dependencies and health
#   status    - Check service status
#   init      - Initialize blockchain and deploy programs
#   reseed    - Re-seed on-chain accounts only (mints/registry/shards), no build/deploy
#   register  - Register admin user
#   seed      - Seed database with test users
#   provision-meter - Create on-chain user + map a meter id to it (Redis)
#   logs      - View service logs
#   solana    - Manage local solana test validator (start/stop)
#
# Examples:
#   ./app.sh start                  # Start everything (terminal)
#   ./app.sh native                 # Start in native background mode
#   ./app.sh docker                 # Start everything in Docker
#   ./app.sh start --skip-ui        # Start without frontend UIs
#   ./app.sh start --docker-only    # Start only Docker infrastructure

set -e

# ============================================================================
# Source all library and command modules
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Library modules (order matters: common first, then others that depend on it)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/services.sh"
source "$SCRIPT_DIR/lib/env.sh"

# Command modules
source "$SCRIPT_DIR/cmd/doctor.sh"
source "$SCRIPT_DIR/cmd/stop.sh"
source "$SCRIPT_DIR/cmd/status.sh"
source "$SCRIPT_DIR/cmd/init.sh"
source "$SCRIPT_DIR/cmd/register.sh"
source "$SCRIPT_DIR/cmd/seed.sh"
source "$SCRIPT_DIR/cmd/seed_apikey.sh"
source "$SCRIPT_DIR/cmd/provision_meter.sh"
source "$SCRIPT_DIR/cmd/onboard_meter.sh"
source "$SCRIPT_DIR/cmd/logs.sh"
source "$SCRIPT_DIR/cmd/start.sh"
source "$SCRIPT_DIR/cmd/solana.sh"

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
        native)
            cmd_start native "$@"
            ;;
        docker)
            cmd_start docker "$@"
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
        reseed)
            cmd_reseed
            ;;
        register)
            cmd_register "$@"
            ;;
        seed)
            cmd_seed
            ;;
        seed-apikey)
            cmd_seed_apikey
            ;;
        check-apikey)
            cmd_check_apikey "$@"
            ;;
        provision-meter)
            cmd_provision_meter "$@"
            ;;
        provision-meters)
            cmd_provision_meters "$@"
            ;;
        onboard-meter)
            cmd_onboard_meter "$@"
            ;;
        logs)
            cmd_logs "$@"
            ;;
        solana)
            cmd_solana "$@"
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
