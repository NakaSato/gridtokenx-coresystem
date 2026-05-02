#!/bin/bash
# scripts/check-balance.sh - Verify GRX token balance for a prosumer

if [ -z "$1" ]; then
    echo "Usage: $0 <wallet_address>"
    exit 1
fi

WALLET=$1
MINT="n52aKuZwUeZAocpWqRZAJR4xFhQqAvaRE7Xepy2JBGk"

echo "🔍 Checking GRX balance for $WALLET..."

# Add solana to path if needed
export PATH=$PATH:/Users/chanthawat/.local/share/solana/install/active_release/bin

# Get balance using spl-token CLI
BALANCE_RAW=$(spl-token balance --address $WALLET $MINT 2>/dev/null || echo "0")

echo "💰 Current Balance: $BALANCE_RAW GRX"

# Exit with success if balance > 0
if (( $(echo "$BALANCE_RAW > 0" | bc -l) )); then
    exit 0
else
    exit 1
fi
