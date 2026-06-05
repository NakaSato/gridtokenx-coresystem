#!/bin/bash
# GridTokenX - Solana Localnet Script

source "$SCRIPT_DIR/lib/common.sh"

cmd_solana() {
    local action="${1:-start}"

    case "$action" in
        start|up)
            solana_validator_start
            ;;
        stop|down)
            solana_validator_stop
            ;;
        *)
            log_error "Unknown action: $action"
            echo "Usage: ./app.sh solana [start|stop]"
            exit 1
            ;;
    esac
}
