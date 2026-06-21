#!/bin/bash
# GridTokenX - Init command (blockchain deployment)

# Ensure the platform dev / fee-payer keypair exists. Sets $DEV_WALLET (path) and
# $DEV_PUBKEY. This key MUST equal Chain Bridge's CHAIN_BRIDGE_INSECURE signer
# (EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ) so that registry.authority ==
# the register_user fee-payer (otherwise register_user fails UnauthorizedAuthority).
# NOT a secret — same public bytes embedded in gridtokenx-chain-bridge/src/vault.rs.
_ensure_dev_wallet() {
    DEV_WALLET=${DEV_WALLET:-"$PROJECT_ROOT/dev-wallet.json"}
    if [ ! -f "$DEV_WALLET" ]; then
        log_warn "DEV_WALLET not found at $DEV_WALLET — writing well-known insecure dev keypair"
        cat > "$DEV_WALLET" <<'DEVWALLET'
[241,3,15,11,59,189,0,251,20,183,69,181,3,24,241,148,23,179,177,88,214,187,29,157,2,66,127,53,53,185,21,209,207,253,141,144,58,192,105,53,193,102,73,89,250,146,246,181,133,48,6,16,231,20,229,155,54,191,88,204,36,39,161,251]
DEVWALLET
    fi
    DEV_PUBKEY=$(solana-keygen pubkey "$DEV_WALLET" 2>/dev/null || echo "")
}

# Airdrop SOL to the dev wallet so it can pay deploy + bootstrap rent/fees.
# Localnet only (no-op against any non-local RPC).
_fund_dev_wallet() {
    if [ -n "$DEV_PUBKEY" ] && { [[ "$RPC_URL" == *localhost* ]] || [[ "$RPC_URL" == *127.0.0.1* ]]; }; then
        log_info "Airdropping 100 SOL to dev wallet $DEV_PUBKEY (localnet)..."
        solana airdrop 100 "$DEV_PUBKEY" --url "$RPC_URL" >/dev/null 2>&1 \
            || log_warn "Airdrop failed (faucet limit or already funded; continuing)"
    fi
}

# (Re)create on-chain ACCOUNT state — mints, registry config + vaults, 16 registry
# shards — and propagate derived addresses into .env. Does NOT build or deploy
# programs. Runs bootstrap + init-shards with ANCHOR_WALLET=DEV_WALLET so
# registry.authority is set to the Chain Bridge payer from creation (no separate
# update_authority step). Idempotent: after a ledger reset it recreates the gone
# accounts and skips any that survived. Expects $RPC_URL, $ANCHOR_DIR, $DEV_WALLET,
# $DEV_PUBKEY already set (call _ensure_dev_wallet first).
_init_onchain_accounts() {
    cd "$ANCHOR_DIR"
    export ANCHOR_PROVIDER_URL="$RPC_URL"
    export ANCHOR_WALLET="$DEV_WALLET"

    # bootstrap.ts / init-shards.ts are tsx scripts — they need node_modules present.
    if [ ! -d "$ANCHOR_DIR/node_modules" ]; then
        log_info "Installing Anchor JS deps (node_modules absent)..."
        npm install || log_warn "npm install failed — bootstrap/shard scripts may not run."
    fi

    log_info "Bootstrapping on-chain accounts (mints, registry config, vaults)..."
    if [ -n "$DEV_PUBKEY" ]; then
        log_info "Authorizing dev-wallet ($DEV_PUBKEY) as Oracle API Gateway..."
        ORACLE_API_GATEWAY="$DEV_PUBKEY" npx tsx scripts/bootstrap.ts || log_warn "Bootstrap script failed, but continuing..."
    else
        npx tsx scripts/bootstrap.ts || log_warn "Bootstrap script failed, but continuing..."
    fi

    log_info "Initializing Registry Shards (16)..."
    npx tsx scripts/init-shards.ts || log_warn "Shard initialization failed, but continuing..."

    log_info "Extracting PDAs and Mint addresses..."
    local pda_config energy_mint currency_mint registry_pda trading_market_pda collector_wallet
    pda_config=$(npx tsx scripts/get_pdas.ts 2>/dev/null || echo "")
    energy_mint=$(echo "$pda_config" | grep "ENERGY_TOKEN_MINT=" | cut -d'=' -f2)
    currency_mint=$(echo "$pda_config" | grep "CURRENCY_TOKEN_MINT=" | cut -d'=' -f2)
    registry_pda=$(echo "$pda_config" | grep "REGISTRY_PDA=" | cut -d'=' -f2)
    trading_market_pda=$(echo "$pda_config" | grep "MARKET_PDA=" | cut -d'=' -f2)
    collector_wallet=${DEV_PUBKEY:-}

    local REGISTRY_ID ENERGY_TOKEN_ID TRADING_ID ORACLE_ID GOVERNANCE_ID
    REGISTRY_ID=$(grep -E "^registry =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    ENERGY_TOKEN_ID=$(grep -E "^energy_token =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    TRADING_ID=$(grep -E "^trading =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    ORACLE_ID=$(grep -E "^oracle =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)
    GOVERNANCE_ID=$(grep -E "^governance =" "$ANCHOR_DIR/Anchor.toml" | cut -d '"' -f 2)

    propagate_program_ids \
        "$REGISTRY_ID" "$ENERGY_TOKEN_ID" "$TRADING_ID" "$ORACLE_ID" "$GOVERNANCE_ID" \
        "$energy_mint" "$currency_mint" "$registry_pda" "$trading_market_pda" \
        "$collector_wallet" "$collector_wallet" "$collector_wallet"
}

cmd_init() {
    # Load Environment
    if [ -f "$PROJECT_ROOT/.env" ]; then
        set -a; source "$PROJECT_ROOT/.env"; set +a
    fi
    # Fallback default RPC_URL and ANCHOR_DIR
    RPC_URL=${RPC_URL:-"http://localhost:8899"}
    ANCHOR_DIR=${ANCHOR_DIR:-"$PROJECT_ROOT/gridtokenx-anchor"}

    _ensure_dev_wallet

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
    _fund_dev_wallet

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

    # Let freshly deployed programs settle before the account-init txs reference them.
    sleep 5

    _init_onchain_accounts

    log_success "Blockchain initialization complete!"
}

# Re-seed on-chain ACCOUNT state only — no anchor build, no program deploy. Use
# after a native validator ledger reset where programs are still deployed but their
# accounts are gone. Symptoms it fixes (chain-bridge "pre-sign simulation failed"):
#   InstructionError(0, Custom(2))    -> mints gone (InvalidMint on ATA create)
#   InstructionError(1, Custom(3007)) -> registry shards gone (AccountOwnedByWrongProgram)
#   InstructionError(1, Custom(6001)) -> registry re-created with wrong authority
# Far faster than a full `init`; requires a reachable validator with the programs
# already deployed.
cmd_reseed() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        set -a; source "$PROJECT_ROOT/.env"; set +a
    fi
    RPC_URL=${RPC_URL:-"http://localhost:8899"}
    ANCHOR_DIR=${ANCHOR_DIR:-"$PROJECT_ROOT/gridtokenx-anchor"}

    show_banner
    log_info "Re-seeding on-chain accounts (no build / no deploy)..."
    echo ""

    if ! command -v solana &> /dev/null; then
        log_error "solana CLI is not installed"
    fi
    if ! curl -s "$RPC_URL/health" > /dev/null 2>&1; then
        log_error "Solana validator not reachable at $RPC_URL — start it first (e.g. 'just solana-up')."
    fi

    _ensure_dev_wallet
    _fund_dev_wallet
    _init_onchain_accounts

    log_success "On-chain account re-seed complete!"
}
