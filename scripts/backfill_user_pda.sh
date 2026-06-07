#!/usr/bin/env bash
#
# backfill_user_pda.sh — repair users whose on-chain identity was persisted with
# the wrong Registry PDA seed (b"user_account" instead of b"user") and/or a
# placeholder wallet_address left over from the old verify-time mock wallet.
#
# For every user that has a primary wallet it:
#   - sets users.wallet_address  = the primary wallet (clears legacy mock)
#   - recomputes users.user_account_pda = PDA([b"user", primary_wallet], registry)
#
# Idempotent. Dry-run by default; pass --apply to write.
#
# Env: REGISTRY_PROGRAM_ID (default = from .env SOLANA_REGISTRY_PROGRAM_ID),
#      PG_CONTAINER (default gridtokenx-postgres), PGUSER/PGDB.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=0; [[ "${1:-}" == "--apply" ]] && APPLY=1
PG_CONTAINER="${PG_CONTAINER:-postgres}"   # docker compose *service* name
PGUSER="${PGUSER:-gridtokenx_user}"
PGDB="${PGDB:-gridtokenx}"
REGISTRY="${REGISTRY_PROGRAM_ID:-$(grep -E '^SOLANA_REGISTRY_PROGRAM_ID=' "$ROOT/.env" 2>/dev/null | cut -d= -f2)}"

command -v solana >/dev/null || { echo "FATAL: solana CLI required"; exit 1; }
[[ -n "$REGISTRY" ]] || { echo "FATAL: REGISTRY_PROGRAM_ID unset"; exit 1; }
echo "registry=$REGISTRY  apply=$APPLY"

psql() { docker compose -f "$ROOT/docker-compose.yml" exec -T "$PG_CONTAINER" \
           psql -U "$PGUSER" -d "$PGDB" -tAc "$1" 2>/dev/null | grep -v level=warning; }

# users with a primary wallet: id | primary_wallet | current_pda | current_addr
# Only users actually registered on-chain: a PDA is only meaningful once the
# Registry RegisterUser tx has run. Non-registered users get fixed naturally the
# next time they link/register, so inventing a PDA for them would be misleading.
rows=$(psql "SELECT u.id, w.wallet_address, COALESCE(u.user_account_pda,''), COALESCE(u.wallet_address,'')
            FROM users u
            JOIN user_wallets w ON w.user_id = u.id AND w.is_primary = true
            WHERE u.blockchain_registered = true;")

[[ -z "$rows" ]] && { echo "no users with a primary wallet"; exit 0; }

n=0; fixed=0
while IFS='|' read -r uid wallet cur_pda cur_addr; do
  [[ -z "$uid" ]] && continue
  ((n++))
  want_pda=$(solana find-program-derived-address "$REGISTRY" string:user "pubkey:$wallet" 2>/dev/null)
  if [[ -z "$want_pda" ]]; then echo "  ! $uid bad wallet $wallet — skip"; continue; fi
  if [[ "$cur_pda" == "$want_pda" && "$cur_addr" == "$wallet" ]]; then
    echo "  = $uid ok"; continue
  fi
  echo "  ~ $uid  addr:$cur_addr->$wallet  pda:$cur_pda->$want_pda"
  ((fixed++))
  if (( APPLY == 1 )); then
    psql "UPDATE users SET wallet_address='$wallet', user_account_pda='$want_pda' WHERE id='$uid';" >/dev/null
  fi
done <<< "$rows"

echo "scanned=$n  $([[ $APPLY == 1 ]] && echo fixed || echo would-fix)=$fixed"
(( APPLY == 1 )) || echo "dry-run — re-run with --apply to write"
