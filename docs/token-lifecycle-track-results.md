# GRID token lifecycle track — mint / settle / burn

Tracks the GRID energy token (`GktSLt9dFsTrSSxikMEQRNeQXhpN9NxUn4m9teixctVS`,
Token-2022, 9 decimals) through its three on-chain supply operations, captured
against the live local stack. Reproduce with
[`scripts/token_lifecycle_track.sh`](../scripts/token_lifecycle_track.sh).

## The three operations

| Op | Mechanism | Live trigger | Supply effect |
|---|---|---|---|
| **MINT** | aggregator surplus → NATS `chain.tx.mint` → energy-token `MintGeneration` | yes (aggregator-signed) | **↑** minted to the generating meter's owner |
| **SETTLE** | trading `ExecuteAtomicSettlement` (atomic swap) | yes (trading settlement worker) | **neutral** — transfer only |
| **BURN** | `retire_energy_tokens` == `token_interface::burn` (owner-signed) | **no** — chain-bridge subjects are submit/cancel/mint/mintbatch/status, no burn | **↓** burned from the holder |

## Observed results (per-tx pre/post token balances)

Owners abbreviated to 8 chars; amounts in GRID (and the settlement currency mint
`AzFyFd4G`).

### MINT — surplus generation mint
- meter `259e5a8a…`, +5 kWh forced into a closed window
- sig `5JT71TS2NidPFeuzjAKiDfp72yfME3VQaYUkE7GzcHh4Z6LVKnysntrkMSnj3c2feFcbp6VV44oy8LcCDZDnQcKf`, slot 12432, `err None`
- effect: **+5 GRID** minted to the owner ATA (`getTokenSupply` rises)

### SETTLE — atomic swap (supply-neutral)
- sig `38VRC6YKx79HT4jotaAzWTobpLFoi5bryz7EQYNjXzKPCqXaaxNRfHQK256rDLhJfkmwCbjoYAt2HruLHSwL4xtH`, slot 13130, `err None`

| mint | owner | delta |
|---|---|---|
| `GktSLt9d` (GRID) | `EzudwoHv` (escrow) | **−5.0000** |
| `GktSLt9d` (GRID) | `Dxmh84hX` (buyer) | **+5.0000** |
| `AzFyFd4G` (currency) | `EzudwoHv` (escrow) | **−19.4900** |
| `AzFyFd4G` (currency) | `D7gKumM6` (seller) | **+19.4400** |
| `AzFyFd4G` (currency) | `BT9ESAZo` (fee collector) | **+0.0500** |

GRID nets to zero in the tx — the energy leg moves buyer↔escrow, the currency leg
moves seller↔escrow plus a 0.05 fee. Total supply of both mints is unchanged.

### BURN — retire / token burn (supply-down)
- sig `51FNmHSsqvVauoD7TsmbD7MVwpdMWxjcgp3kAszTviACkRwUScaqZi31CnywhNdE9aHosRNBv5AVCVDHPWRVY3uV`, slot 13306, `err None`

| mint | owner | pre | post | delta |
|---|---|---|---|---|
| `GktSLt9d` (GRID) | `EzudwoHv` | 999929.0000 | 999924.0000 | **−5.0000** |

Burned 5 GRID from the holder ATA; total supply drops by 5. (Demonstrated with the
dev-wallet as owner, since live e2e owners are custodial/Vault wallets and cannot
be locally signed. The instruction path is identical — `retire_energy_tokens`
CPIs straight into `token_interface::burn`.)

## Caveat — read per-op deltas from the tx, not the supply counter

The smartmeter-simulator streams real telemetry for every claimed meter, so
**organic surplus mints fire continuously** (~+5 GRID per 15-min window). At the
total-supply level this masks a single op's delta — e.g. a burn of −5 landing
alongside an organic +5 leaves the supply counter flat. Always isolate an op's
effect from its own transaction's `preTokenBalances` / `postTokenBalances`
(`token_lifecycle_track.sh delta <sig>`), which is exact regardless of background
activity.

## Reproduce

```bash
scripts/token_lifecycle_track.sh supply                 # GRID total supply
scripts/token_lifecycle_track.sh balance <owner_pubkey> # an owner's GRID balance
scripts/token_lifecycle_track.sh delta <tx_sig>         # per-mint/owner deltas of a tx
scripts/token_lifecycle_track.sh burn <ata> <amount> <owner_keypair>   # supply-down leg
```

- MINT: onboard a meter (`gridtokenx-smartmeter-simulator/backend/scripts/e2e_iam_flow.py`)
  then force a surplus (`.claude/skills/telemetry-hops/scripts/force_surplus.py --encrypt --at <aligned window>`),
  and `delta <mint_sig>`.
- SETTLE: run `scripts/e2e_two_user_trade.sh`, grab the settlement sig from the
  trading-service log (`successful on-chain: <sig>`), and `delta <sig>`.
- BURN: `burn <ata> <amount> <owner_keypair>` against any GRID-holding ATA you can sign for.

> Sigs above are pruned from the local ledger over time (`--limit-ledger-size`);
> re-run to capture fresh ones.

## Run log

### Clean-slate register→trading E2E (via `scripts/cleanup_and_e2e.sh`)

Full reset (6 DBs truncated, Redis flushed, services restarted, api key re-seeded)
then a fresh register→trading run. IAM users 0→2.

- SETTLE sig `EkV3wWGw5xz1hLvnRn7MJW89WdZYuLuo4nqAcRWGu2sZj6WTELqPdpf2ThgQ1VC6tSjdmnEAn8xUy8vh7qncobG`, slot 78930, `err None`

| mint | owner | delta |
|---|---|---|
| `GktSLt9d` (GRID) | `EzudwoHv` (escrow) | **−5.0000** |
| `GktSLt9d` (GRID) | `C4Po6vue` (buyer) | **+5.0000** |
| `AzFyFd4G` (currency) | `EzudwoHv` (escrow) | **−19.4900** |
| `AzFyFd4G` (currency) | `GpudHmH3` (seller) | **+19.4400** |
| `AzFyFd4G` (currency) | `BT9ESAZo` (fee) | **+0.0500** |

Same supply-neutral swap shape as above. On a cold post-wipe read-model the
consumer's wallet row was absent; resolution **self-healed** via the lazy
IAM-source reconcile (`trading-infra`, submodule `690c4da`) — order still got a
PDA and settled, no manual step. Fresh-DB counts after: iam.users=2, orders=2,
settlements completed=1.
