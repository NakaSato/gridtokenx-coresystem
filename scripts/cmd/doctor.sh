#!/bin/bash
# GridTokenX - Doctor command (dependency and health checks)

check_dependencies() {
    local missing=()
    local deps=("docker" "solana" "anchor" "bun" "cargo" "uv" "jq" "curl")

    log_info "Checking system dependencies..."
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    # Check for rustup and toolchain
    if command -v rustup &> /dev/null; then
        local required_toolchain="1.89.0-sbpf-solana-v1.52"
        if ! rustup toolchain list | grep -q "$required_toolchain"; then
            log_warn "Required toolchain $required_toolchain not found. Attempting to install..."
            rustup toolchain install "$required_toolchain" || log_error "Failed to install toolchain $required_toolchain"
        fi
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_warn "Missing dependencies: ${missing[*]}"
        return 1
    fi
    log_success "All core dependencies found."
    return 0
}

cmd_doctor() {
    show_banner
    log_info "Running GridTokenX System Doctor..."
    echo ""

    # Check dependencies
    check_dependencies || log_warn "Please install missing dependencies to ensure all services can start."

    # Check OrbStack requirement
    check_orbstack || log_error "OrbStack is required but not properly configured."

    # Show OrbStack version if available
    if [ "$DOCKER_RUNTIME" = "orbstack" ] && command -v orb &>/dev/null; then
        log_success "OrbStack CLI found: $(orb --version 2>/dev/null || echo 'installed')"
    fi
    
    # Check Solana tools
    if command -v solana &>/dev/null; then
        local solana_ver=$(solana --version | head -n 1)
        log_success "Solana CLI found: $solana_ver"
    fi
    
    # Check Node.js/Bun
    if command -v bun &>/dev/null; then
        log_success "Bun found: $(bun --version)"
    fi
    
    echo ""
    log_info "Diagnostic complete!"
}
