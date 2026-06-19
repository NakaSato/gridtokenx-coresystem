#!/bin/bash
# GridTokenX - Solana Localnet Script

source "$SCRIPT_DIR/lib/common.sh"

cmd_solana() {
    local action="${1:-start}"
    shift 2>/dev/null || true
    # Remaining args pass straight through to solana-test-validator, e.g.:
    #   ./app.sh solana start --bpf-program <ID> path/to/program.so
    #   ./app.sh solana start --account <PUBKEY> fixtures/acct.json --slots-per-epoch 32
    local extra_args="$*"

    case "$action" in
        start|up)
            solana_validator_start \
                "$PROJECT_ROOT/test-ledger" \
                "$PROJECT_ROOT/scripts/logs/validator.log" \
                "$extra_args"
            # Block until RPC answers so callers get a ready validator (start/init do this too).
            wait_for_solana
            # Auto-kill after TTL (default 1h) so a forgotten dev validator can't linger.
            # Disable with SOLANA_VALIDATOR_TTL=0.
            solana_validator_schedule_kill "${SOLANA_VALIDATOR_TTL:-3600}"
            ;;
        stop|down)
            solana_validator_stop
            ;;
        status)
            if solana cluster-version --url "$RPC_URL" &>/dev/null; then
                log_success "Solana validator running ($RPC_URL)"
            else
                log_warn "Solana validator not reachable ($RPC_URL)"
                return 1
            fi
            ;;
        *)
            log_error "Unknown action: $action"
            echo "Usage: ./app.sh solana [start|stop|status] [extra solana-test-validator args]"
            exit 1
            ;;
    esac
}
