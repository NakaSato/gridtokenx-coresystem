#!/usr/bin/env bash
# Provision the Vault Transit KEK that wraps per-meter AES-256 GUEKs
# (smart-meter telemetry encryption, Phase 3 key rotation).
#
# The dev Vault (`gridtokenx-vault`, dev mode) is in-memory, so its transit
# engine + keys are lost on container restart. Run this after `just orb-up`
# (or it is re-applied by the Aggregator Bridge on startup, which self-heals
# the same key idempotently). Safe to re-run: enable/create are no-ops if the
# engine/key already exist.
set -euo pipefail

VAULT_CONTAINER="${VAULT_CONTAINER:-gridtokenx-vault}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
KEK_NAME="${VAULT_METER_KEK_NAME:-gridtokenx-meter-kek}"

vault_exec() {
    docker exec -e VAULT_TOKEN="$VAULT_TOKEN" -e VAULT_ADDR=http://127.0.0.1:8200 \
        "$VAULT_CONTAINER" vault "$@"
}

echo "Ensuring transit secrets engine is enabled…"
if ! vault_exec secrets list 2>/dev/null | grep -q '^transit/'; then
    vault_exec secrets enable transit
else
    echo "  transit/ already enabled"
fi

echo "Ensuring transit key '$KEK_NAME' (aes256-gcm96) exists…"
if ! vault_exec read "transit/keys/$KEK_NAME" >/dev/null 2>&1; then
    vault_exec write -f "transit/keys/$KEK_NAME" >/dev/null
    echo "  created $KEK_NAME"
else
    echo "  $KEK_NAME already exists"
fi

echo "Done. KEK '$KEK_NAME' ready to wrap per-meter GUEKs."
