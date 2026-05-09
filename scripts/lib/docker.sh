#!/bin/bash
# GridTokenX - Docker runtime detection and OrbStack checks

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
