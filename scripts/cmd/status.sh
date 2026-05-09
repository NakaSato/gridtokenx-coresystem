#!/bin/bash
# GridTokenX - Status command

cmd_status() {
    show_banner

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
