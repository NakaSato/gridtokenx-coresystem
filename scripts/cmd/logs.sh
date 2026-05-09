#!/bin/bash
# GridTokenX - Logs command

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
