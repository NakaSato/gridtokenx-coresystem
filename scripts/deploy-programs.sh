#!/usr/bin/env bash
# One-shot: pin program keypairs -> build -> deploy every program with the
# CORRECT upgrade authority auto-resolved -> propagate program IDs into all
# .env files. Automates the manual dance (pin, build, wallet-mismatch fix,
# env sync) into a single command.
#
# Why auto-resolve the upgrade authority: on a localnet that has been through
# a bootstrap/reset the on-chain ProgramData authority is often the dev funder
# (dev-wallet.json), not `solana config`'s default keypair — `anchor deploy`
# then dies with "Upgrade authority mismatch". This script reads each
# program's on-chain authority and picks the matching keypair automatically.
#
# Usage:
#   ./scripts/deploy-programs.sh              # pin + build + deploy + sync env
#   ./scripts/deploy-programs.sh --skip-build # deploy already-built .so
#   ./scripts/deploy-programs.sh --no-sync    # skip the env-sync step
#   ./scripts/deploy-programs.sh --dry-run    # show plan, deploy nothing
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
ANCHOR_DIR="$ROOT/gridtokenx-anchor"

SKIP_BUILD=0; NO_SYNC=0; DRY=0
for a in "$@"; do
  case "$a" in
    --skip-build) SKIP_BUILD=1 ;;
    --no-sync)    NO_SYNC=1 ;;
    --dry-run)    DRY=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

RPC="${SOLANA_RPC_URL:-http://127.0.0.1:8899}"
cd "$ANCHOR_DIR"

# --- 0. sanity: validator reachable (advisory in dry-run) ---
if ! solana cluster-version --url "$RPC" >/dev/null 2>&1; then
  if [ "$DRY" = 1 ]; then
    echo "WARN: no validator at $RPC — dry-run continues (plan only, no on-chain reads)" >&2
  else
    echo "ERROR: no validator at $RPC — start one (just solana-up / surfpool) first" >&2
    exit 1
  fi
else
  echo "validator OK @ $RPC"
fi

# --- 1. pin the vendored program keypairs into target/deploy ---
if [ -x scripts/pin-program-keys.sh ]; then
  echo "== pin program keypairs =="
  [ "$DRY" = 1 ] && echo "  [dry-run] would run scripts/pin-program-keys.sh" || ./scripts/pin-program-keys.sh
fi

# --- 2. build ---
if [ "$SKIP_BUILD" = 0 ]; then
  echo "== anchor build =="
  [ "$DRY" = 1 ] && echo "  [dry-run] would run anchor build" || anchor build
else
  echo "== skip build =="
fi

# --- collect candidate upgrade-authority keypairs (pubkey -> path) ---
CAND_PATHS=()
for p in "$ANCHOR_DIR/dev-wallet.json" "$HOME/.config/solana/id.json"; do
  [ -f "$p" ] && CAND_PATHS+=("$p")
done
while IFS= read -r kp; do CAND_PATHS+=("$kp"); done < <(find "$ANCHOR_DIR/keys" -name '*.json' 2>/dev/null || true)

authority_keypair_for() {   # arg: expected authority pubkey -> echoes keypair path
  local want="$1" p pub
  for p in "${CAND_PATHS[@]}"; do
    pub="$(solana-keygen pubkey "$p" 2>/dev/null || true)"
    [ "$pub" = "$want" ] && { echo "$p"; return 0; }
  done
  return 1
}

# --- 3. deploy each program with the right authority ---
echo "== deploy programs =="
deploy_fail=0
for kp in target/deploy/*-keypair.json; do
  [ -f "$kp" ] || continue
  prog="$(basename "$kp" -keypair.json)"
  so="target/deploy/$prog.so"
  [ -f "$so" ] || { echo "  skip $prog (no .so)"; continue; }
  pid="$(solana-keygen pubkey "$kp")"

  # existing on-chain authority? (empty if program not yet deployed / no validator)
  auth="$( { solana program show "$pid" --url "$RPC" 2>/dev/null || true; } | awk -F': *' '/Authority/{print $2}')"

  if [ -n "$auth" ]; then
    wallet="$(authority_keypair_for "$auth" || true)"
    if [ -z "$wallet" ]; then
      echo "  !! $prog: on-chain authority $auth has no matching keypair among candidates — SKIP" >&2
      deploy_fail=1; continue
    fi
    action="upgrade (authority $auth)"
  else
    wallet="$ANCHOR_DIR/dev-wallet.json"; [ -f "$wallet" ] || wallet="$HOME/.config/solana/id.json"
    action="fresh deploy (authority $(solana-keygen pubkey "$wallet"))"
  fi

  echo "  $prog $pid -> $action  [wallet=$(basename "$wallet")]"
  if [ "$DRY" = 0 ]; then
    if solana program deploy "$so" \
        --program-id "$kp" \
        --upgrade-authority "$wallet" \
        --keypair "$wallet" \
        --url "$RPC" >/dev/null 2>&1; then
      echo "     deployed"
    else
      echo "     FAILED" >&2; deploy_fail=1
    fi
  fi
done

# --- 4. propagate IDs into every .env ---
if [ "$NO_SYNC" = 0 ]; then
  echo "== sync env program IDs =="
  if [ "$DRY" = 1 ]; then
    "$ROOT/scripts/sync-env-program-ids.sh" --dry-run
  else
    "$ROOT/scripts/sync-env-program-ids.sh"
  fi
fi

echo
[ "$deploy_fail" = 0 ] && echo "OK — programs deployed + env in sync" || { echo "DONE with errors (see above)"; exit 1; }
