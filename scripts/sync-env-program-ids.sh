#!/usr/bin/env bash
# Propagate the canonical localnet program IDs (and mints/PDA) into every
# .env / .env.example across the superproject and its submodules.
#
# Why: program IDs live in gridtokenx-anchor/Anchor.toml [programs.localnet]
# (pinned via scripts/pin-program-keys.sh). Many services + frontends carry a
# copy in their own .env. After a redeploy, key rotation, or a fresh clone
# those copies drift, silently breaking on-chain calls. This script makes
# Anchor.toml the single source of truth and rewrites every matching env key.
#
# Sources of truth:
#   - program IDs  <- gridtokenx-anchor/Anchor.toml [programs.localnet]
#   - mints / PDA  <- root .env (ENERGY_TOKEN_MINT, CURRENCY_TOKEN_MINT,
#                     REGISTRY_PDA) — these are runtime chain state, override
#                     with env vars below when re-initializing.
#
# Only keys that ALREADY exist in a file are rewritten (never adds new keys).
# Placeholder values are preserved: a key whose current value is empty or
# starts with CHANGE_ME is left untouched (protects *.production.example and
# blank templates). Pass --fill-blanks to also populate empty values.
#
# Usage:
#   ./scripts/sync-env-program-ids.sh            # sync all env files
#   ./scripts/sync-env-program-ids.sh --dry-run  # show changes, write nothing
#   ./scripts/sync-env-program-ids.sh --fill-blanks
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"

DRY=0
FILL_BLANKS=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --fill-blanks) FILL_BLANKS=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

ANCHOR_TOML="$ROOT/gridtokenx-anchor/Anchor.toml"
[ -f "$ANCHOR_TOML" ] || { echo "ERROR: $ANCHOR_TOML not found" >&2; exit 1; }

# --- pull canonical program IDs from Anchor.toml [programs.localnet] ---
prog_id() { awk -v k="$1" '/^\[programs.localnet\]/{f=1;next} /^\[/{f=0} f && $1==k {gsub(/"/,"",$3); print $3}' "$ANCHOR_TOML"; }
REGISTRY="$(prog_id registry)"
TRADING="$(prog_id trading)"
ORACLE="$(prog_id oracle)"
GOVERNANCE="$(prog_id governance)"
ENERGY_TOKEN="$(prog_id energy_token)"
TREASURY="$(prog_id treasury)"
BLOCKBENCH="$(prog_id blockbench)"
TPC="$(prog_id tpc_benchmark)"

# --- pull runtime mints/PDA from root .env (override via env) ---
root_env_val() { [ -f "$ROOT/.env" ] && grep -E "^$1=" "$ROOT/.env" | head -1 | cut -d= -f2- || true; }
ENERGY_TOKEN_MINT="${ENERGY_TOKEN_MINT:-$(root_env_val ENERGY_TOKEN_MINT)}"
CURRENCY_TOKEN_MINT="${CURRENCY_TOKEN_MINT:-$(root_env_val CURRENCY_TOKEN_MINT)}"
REGISTRY_PDA="${REGISTRY_PDA:-$(root_env_val REGISTRY_PDA)}"

for v in REGISTRY TRADING ORACLE GOVERNANCE ENERGY_TOKEN TREASURY BLOCKBENCH TPC; do
  [ -n "${!v}" ] || { echo "ERROR: program id '$v' missing from Anchor.toml" >&2; exit 1; }
done

echo "Canonical program IDs (from Anchor.toml):"
printf "  %-14s %s\n" registry "$REGISTRY" trading "$TRADING" oracle "$ORACLE" \
  governance "$GOVERNANCE" energy_token "$ENERGY_TOKEN" treasury "$TREASURY" \
  blockbench "$BLOCKBENCH" tpc_benchmark "$TPC"
echo "Runtime (from root .env):"
printf "  %-20s %s\n" ENERGY_TOKEN_MINT "$ENERGY_TOKEN_MINT" \
  CURRENCY_TOKEN_MINT "$CURRENCY_TOKEN_MINT" REGISTRY_PDA "$REGISTRY_PDA"
echo

# --- map an env KEY (any prefix) to its canonical value; empty = not managed ---
# Handles bare, SOLANA_, and NEXT_PUBLIC_ prefixes.
value_for_key() {
  local k="$1"
  case "$k" in
    *REGISTRY_PROGRAM_ID)      echo "$REGISTRY" ;;
    *TRADING_PROGRAM_ID)       echo "$TRADING" ;;
    *ORACLE_PROGRAM_ID)        echo "$ORACLE" ;;
    *GOVERNANCE_PROGRAM_ID)    echo "$GOVERNANCE" ;;
    *ENERGY_TOKEN_PROGRAM_ID)  echo "$ENERGY_TOKEN" ;;
    *TREASURY_PROGRAM_ID)      echo "$TREASURY" ;;
    *BLOCKBENCH_PROGRAM_ID)    echo "$BLOCKBENCH" ;;
    *TPC_BENCHMARK_PROGRAM_ID) echo "$TPC" ;;
    # explorer names energy-token program NEXT_PUBLIC_TOKEN_PROGRAM_ID
    *TOKEN_PROGRAM_ID)         echo "$ENERGY_TOKEN" ;;
    *ENERGY_TOKEN_MINT)        echo "$ENERGY_TOKEN_MINT" ;;
    *CURRENCY_TOKEN_MINT)      echo "$CURRENCY_TOKEN_MINT" ;;
    REGISTRY_PDA)              echo "$REGISTRY_PDA" ;;
    *) echo "" ;;
  esac
}

# --- discover every env file, skip vendored/build/worktree dirs ---
# (bash 3.2 on macOS has no mapfile; read into an array the portable way)
FILES=()
while IFS= read -r _f; do FILES+=("$_f"); done < <(find "$ROOT" \
  \( -name node_modules -o -name target -o -name .git -o -name .next -o -name worktrees \) -prune -o \
  -type f \( -name '.env' -o -name '.env.*' -o -name 'secure.env' \) -print | sort)

total_changed=0
for f in "${FILES[@]}"; do
  file_changed=0
  # iterate KEY=... lines that look like a managed key
  while IFS= read -r line; do
    key="${line%%=*}"
    cur="${line#*=}"
    want="$(value_for_key "$key")"
    [ -n "$want" ] || continue                 # key not managed
    [ "$cur" = "$want" ] && continue           # already correct
    # preserve placeholders
    case "$cur" in
      CHANGE_ME*) continue ;;
      "") [ "$FILL_BLANKS" = 1 ] || continue ;;
    esac
    [ -z "$want" ] && continue                 # no canonical value available
    if [ "$DRY" = 1 ]; then
      printf "  %s: %s  %s -> %s\n" "${f#$ROOT/}" "$key" "${cur:-<empty>}" "$want"
    else
      sed -i '' "s|^$key=.*|$key=$want|" "$f"
    fi
    file_changed=1
  done < <(grep -E '^[A-Za-z_]+(_PROGRAM_ID|_TOKEN_MINT|REGISTRY_PDA)=' "$f" 2>/dev/null || true)
  if [ "$file_changed" = 1 ]; then
    total_changed=$((total_changed+1))
    [ "$DRY" = 1 ] || echo "synced ${f#$ROOT/}"
  fi
done

echo
if [ "$DRY" = 1 ]; then
  echo "[dry-run] $total_changed file(s) would change"
else
  echo "$total_changed file(s) updated"
fi
