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

check_performance_tuning() {
    log_info "Checking Firedancer / High-Performance readiness..."
    
    # 1. CPU Features
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Check for AVX512 on macOS (Intel) or note ARM status
        local arch=$(uname -m)
        if [ "$arch" = "arm64" ]; then
            log_info "CPU: Apple Silicon (ARM64) detected. AVX512 check skipped (Not applicable)."
        else
            if sysctl -a | grep -qi "avx512"; then
                log_success "CPU: AVX512 support detected ✓"
            else
                log_warn "CPU: AVX512 support not detected. Firedancer performance will be limited on this host."
            fi
        fi
    elif [ -f /proc/cpuinfo ]; then
        if grep -qi "avx512" /proc/cpuinfo; then
            log_success "CPU: AVX512 support detected ✓"
        else
            log_warn "CPU: AVX512 support not detected."
        fi
    fi

    # 2. Hugepages (Linux only)
    if [ -f /proc/sys/vm/nr_hugepages ]; then
        local hp=$(cat /proc/sys/vm/nr_hugepages)
        if [ "$hp" -gt 0 ]; then
            log_success "OS: Hugepages enabled ($hp) ✓"
        else
            log_warn "OS: Hugepages disabled. See docs/architecture/PERFORMANCE_TUNING.md for setup."
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        log_info "OS: Hugepages check skipped (macOS host). Verify this in your Linux production environment."
    fi
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
    check_performance_tuning
    
    echo ""
    log_info "Diagnostic complete!"
}
