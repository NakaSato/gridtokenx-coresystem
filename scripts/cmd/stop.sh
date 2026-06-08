#!/bin/bash
# GridTokenX - Stop command

cmd_stop() {
    show_banner
    echo -e "${YELLOW}Stopping GridTokenX services...${NC}"
    echo ""

    docker stop gridtokenx-apisix 2>/dev/null && log_success "APISIX stopped" || log_warn "APISIX was not running"
    docker stop gridtokenx-envoy 2>/dev/null && log_success "Envoy stopped" || log_warn "Envoy was not running"
    pkill -f "gridtokenx-iam-service" 2>/dev/null && log_success "IAM Service stopped" || log_warn "IAM Service was not running"
    pkill -f "gridtokenx-trading-service" 2>/dev/null && log_success "Trading Service stopped" || log_warn "Trading Service was not running"
    pkill -f "gridtokenx-aggregator-bridge" 2>/dev/null && log_success "Aggregator Bridge stopped" || log_warn "Aggregator Bridge was not running"
    pkill -f "bun run dev" 2>/dev/null || true
    pkill -f "vite" 2>/dev/null || true
    pkill -f "uvicorn" 2>/dev/null || true
    pkill -f "uv run start" 2>/dev/null && log_success "Simulator stopped" || true
    solana_validator_stop

    if [ "$1" == "--all" ]; then
        echo ""
        log_info "Stopping Docker services..."
        cd "$PROJECT_ROOT"
        docker-compose down 2>/dev/null && log_success "OrbStack services stopped" || log_warn "OrbStack services were not running"
    fi

    rm -f "$PID_FILE"
    echo ""
    log_success "All services stopped!"

    if [ "$1" != "--all" ]; then
        echo ""
        log_warn "Note: Docker services (PostgreSQL, Redis) are still running."
        echo "Use '$0 stop --all' to stop everything including Docker."
    fi
}
