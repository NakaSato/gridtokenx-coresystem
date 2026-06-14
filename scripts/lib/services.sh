#!/bin/bash
# GridTokenX - Service wait functions, runners, and port management

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

# Kill processes on GridTokenX ports (skipping Docker-managed ones)
kill_ports() {
    local ports=(4000 4001 4010 4020 4030 5010 5020 5030 5040 6001 6002 6003 6004 6005 6006 7001 7002 7010 7011 7020 7030 8001 9001 9002 9003 9030 9031 10010 10020 10030 10040 10100 10110 10120 10130 10200 10210 10220 10230 11001 11002 12010 12011 13001 13060)
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
