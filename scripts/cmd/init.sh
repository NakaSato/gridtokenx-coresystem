#!/bin/bash
# GridTokenX - Init command (blockchain deployment)

cmd_init() {
    # Load Environment
    if [ -f "$PROJECT_ROOT/.env" ]; then
        set -a; source "$PROJECT_ROOT/.env"; set +a
    fi
    # Fallback default RPC_URL and ANCHOR_DIR
    RPC_URL=${RPC_URL:-"http://localhost:8899"}
    ANCHOR_DIR=${ANCHOR_DIR:-"$PROJECT_ROOT/gridtokenx-anchor"}

    # DEV_WALLET = platform fee-payer / Registry authority keypair. It MUST be the
    # key Chain Bridge signs with in CHAIN_BRIDGE_INSECURE mode — its
    # InsecureKeypairProvider, pubkey EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ.
    # infra/ (which used to ship dev-wallet.json) was removed, so synthesize the
    # well-known insecure dev keypair when absent. NOT a secret: these are the same
    # public bytes already embedded in gridtokenx-chain-bridge/src/vault.rs.
    DEV_WALLET=${DEV_WALLET:-"$PROJECT_ROOT/dev-wallet.json"}
    if [ ! -f "$DEV_WALLET" ]; then
        log_warn "DEV_WALLET not found at $DEV_WALLET — writing well-known insecure dev keypair"
        cat > "$DEV_WALLET" <<'DEVWALLET'
[241,3,15,11,59,189,0,251,20,183,69,181,3,24,241,148,23,179,177,88,214,187,29,157,2,66,127,53,53,185,21,209,207,253,141,144,58,192,105,53,193,102,73,89,250,146,246,181,133,48,6,16,231,20,229,155,54,191,88,204,36,39,161,251]
DEVWALLET
    fi

    show_banner
    log_info "Initializing Blockchain..."
    echo ""

    if ! command -v anchor &> /dev/null; then
        log_error "anchor CLI is not installed. See https://www.anchor-lang.com/docs/installation"
    fi
    if ! command -v solana &> /dev/null; then
        log_error "solana CLI is not installed"
    fi

    log_info "Building Anchor Programs..."
    cd "$ANCHOR_DIR"
    export PATH="$HOME/.cargo/bin:$PATH"
    anchor build

    if ! curl -s "$RPC_URL/health" > /dev/null 2>&1; then
        log_warn "Solana validator not running. Starting it..."
        
        solana_validator_start "$PROJECT_ROOT/test-ledger" "$PROJECT_ROOT/solana.log" ""
        wait_for_solana
    fi

    # Fund the dev wallet so it can pay deploy + bootstrap rent/fees (localnet only).
    local dev_pubkey=$(solana-keygen pubkey "$DEV_WALLET" 2>/dev/null || echo "")
    if [ -n "$dev_pubkey" ] && { [[ "$RPC_URL" == *localhost* ]] || [[ "$RPC_URL" == *127.0.0.1* ]]; }; then
        log_info "Airdropping 100 SOL to dev wallet $dev_pubkey (localnet)..."
        solana airdrop 100 "$dev_pubkey" --url "$RPC_URL" >/dev/null 2>&1 \
            || log_warn "Airdrop failed (faucet limit or already funded; continuing)"
    fi

    log_info "Deploying Programs (Using existing keypairs for consistent IDs)..."

    deploy_program() {
        local NAME=$1
        local ID=$2
        local KEYPAIR="$ANCHOR_DIR/target/deploy/${NAME}-keypair.json"
        # `anchor build` emits each .so under programs/<name>/target/deploy, NOT the
        # workspace target/deploy — fall back to the per-program path so deploys don't
        # silently no-op. (dir uses dashes: energy_token -> energy-token)
        local SO="$ANCHOR_DIR/target/deploy/${NAME}.so"
        [ -f "$SO" ] || SO="$ANCHOR_DIR/programs/${NAME//_/-}/target/deploy/${NAME}.so"
        if [ ! -f "$SO" ]; then
            log_warn "Program binary not found for $NAME (checked target/deploy and programs/${NAME//_/-}/target/deploy) — did 'anchor build' run? Skipping."
            return 1
        fi
        if [ ! -f "$KEYPAIR" ]; then
            log_warn "Program keypair missing: $KEYPAIR (run 'anchor keys sync') — skipping $NAME."
            return 1
        fi
        log_info "Deploying $NAME ($ID) from ${SO#$ANCHOR_DIR/}..."
        # -k "$DEV_WALLET": pay deploy fees + set upgrade authority to the funded dev
        # wallet. No 2>/dev/null — a real failure must be visible (idempotent redeploy
        # of an already-deployed program is itself an upgrade and succeeds).
        solana program deploy \
            --program-id "$KEYPAIR" \
            -k "$DEV_WALLET" \
            "$SO" \
            --url "$RPC_URL" \
            || log_warn "Deploy of $NAME ($ID) did not succeed — check balance/logs above."
    }

    local REGISTRY_ID=$(grep -E "^registry =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    local ENERGY_TOKEN_ID=$(grep -E "^energy_token =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    local TRADING_ID=$(grep -E "^trading =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    local ORACLE_ID=$(grep -E "^oracle =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    local GOVERNANCE_ID=$(grep -E "^governance =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)

    deploy_program "registry" "$REGISTRY_ID"
    deploy_program "energy_token" "$ENERGY_TOKEN_ID"
    deploy_program "trading" "$TRADING_ID"
    deploy_program "oracle" "$ORACLE_ID"
    deploy_program "governance" "$GOVERNANCE_ID"

    log_info "Bootstrapping on-chain accounts..."
    cd "$ANCHOR_DIR"
    export ANCHOR_PROVIDER_URL="$RPC_URL"
    export ANCHOR_WALLET="$DEV_WALLET"

    # bootstrap.ts / init-shards.ts are tsx scripts — they need node_modules present.
    if [ ! -d "$ANCHOR_DIR/node_modules" ]; then
        log_info "Installing Anchor JS deps (node_modules absent)..."
        npm install || log_warn "npm install failed — bootstrap/shard scripts may not run."
    fi
    sleep 5

    if [ -n "$dev_pubkey" ]; then
        log_info "Authorizing dev-wallet ($dev_pubkey) as Oracle API Gateway..."
        ORACLE_API_GATEWAY="$dev_pubkey" npx tsx scripts/bootstrap.ts || log_warn "Bootstrap script failed, but continuing..."
    else
        npx tsx scripts/bootstrap.ts || log_warn "Bootstrap script failed, but continuing..."
    fi

    log_info "Initializing Registry Shards..."
    npx tsx scripts/init-shards.ts || log_warn "Shard initialization failed, but continuing..."

    log_info "Extracting PDAs and Mint addresses..."
    local pda_config=$(npx tsx scripts/get_pdas.ts 2>/dev/null || echo "")
    local energy_mint=$(echo "$pda_config" | grep "ENERGY_TOKEN_MINT=" | cut -d'=' -f2)
    local currency_mint=$(echo "$pda_config" | grep "CURRENCY_TOKEN_MINT=" | cut -d'=' -f2)
    local registry_pda=$(echo "$pda_config" | grep "REGISTRY_PDA=" | cut -d'=' -f2)
    local trading_market_pda=$(echo "$pda_config" | grep "MARKET_PDA=" | cut -d'=' -f2)
    local collector_wallet=${dev_pubkey:-}

    propagate_program_ids \
        "$REGISTRY_ID" "$ENERGY_TOKEN_ID" "$TRADING_ID" "$ORACLE_ID" "$GOVERNANCE_ID" \
        "$energy_mint" "$currency_mint" "$registry_pda" "$trading_market_pda" \
        "$collector_wallet" "$collector_wallet" "$collector_wallet"

    log_success "Blockchain initialization complete!"
}
