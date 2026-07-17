# GridTokenX — Smart Contracts (Anchor Programs)

> On-chain program architecture, account structures, CPI graph, and invariants.
> Status: **(impl)** runs on localnet/LiteSVM · **(designed)** not yet built
> Last reviewed: 2026-07-17

---

## 1. Program Map

Six production programs form the settlement layer. All run on Solana/Anchor (permissioned SVM) — Anchor 1.0.0, SPL Token-2022. The `gridtokenx-anchor/programs/` workspace also contains two benchmark-harness programs (`blockbench`, `tpc-benchmark`) that are not part of the settlement layer.

```
  Governance  FokVuBSPXP1...          (impl)
  PoA authority · AggregatorEntry PDA · ERC-1155 RECs
  admit_aggregator · revoke_aggregator · 2-step authority transfer
       │
       ├── read PoA config + ERC certs ──► Trading  CnWDEUhTvSix...    (impl)
       │                                   CDA order book · off-chain match
       │                                   settle_offchain · batch audit CPI
       │                                        │ record_settlement CPI
       │                                        ▼
       │                                   Treasury  FfxSQYKUmx9NGd...  (impl)
       │                                   GRX↔THBG swap · SettlementRecord PDA
       │                                   yield staking · reserve attestation
       │
       ├── AggregatorEntry PDA validate ──► Oracle  64Vgos61STZ8p...    (impl)
       │                                   AMI gateway · per-meter PDA
       │                                   15-min epoch clearing
       │
Registry  FcSd5x4X1nzJMK...               (impl)
User + Meter accounts · 16-shard counter
Validator bond + slashing · unstake cooldown
       │ airdrop / mint on registration
       ▼
Energy Token  6FZKcVKCLFSNLMx...          (impl)
GRID + GRX SPL mints (Token-2022 + Metaplex)
REC-validator-gated mint · GenerationMintRecord PDA
```

---

## 2. CPI (Cross-Program Invocation) Graph

```
registry   → energy-token    (airdrop + mint on user registration)
trading    → governance      (read PoA config + ERC certificates)
trading    → treasury        (record_settlement_batch — mandatory for THBG markets)
oracle     → governance      (deserialize AggregatorEntry PDA — read only, no CPI invoke)
```

All other cross-program relationships are read-only (deserialize account data). No program calls outside this graph.

---

## 3. Programs — Detail

### 3.1 Governance `FokVuBSPXP1...` (impl)

**Owner (target):** ERC k-of-n multisig council  
**Current code:** single `Pubkey`, 2-step single→single transfer (gap — see `gridtokenx-anchor/docs/design/role-map.md`)

| Instruction | Authority | Who Can Call | Purpose |
|---|---|---|---|
| `admit_aggregator` | ERC / delegated MEA or PEA | ERC, MEA (zone M1/M2), PEA (zones P1-P4) | Create `AggregatorEntry` PDA; assign zone |
| `revoke_aggregator` | ERC | ERC only | Mark entry revoked; blocks token issuance |
| `update_authority` | Current authority | Current authority holder | 2-step transfer |
| `issue_erc_certificate` | Authority | ERC / authority | ERC-1155-style REC certificate |

**Key gap:** `admit_aggregator` is unlinked to the validator bond. `register_validator` must verify an active `AggregatorEntry` PDA — currently a self-granted bond is possible.

---

### 3.2 Registry `FcSd5x4X1nzJMK...` (impl)

**Owner:** EGAT (or the utility operating the platform — MEA / PEA / EGAT)  
**Purpose:** User and meter identity; validator bond and slashing.

| Instruction | Authority / Who Can Call | Description |
|---|---|---|
| `register_user` | Any admitted network participant | Create `UserAccount` PDA; 10 GRX new-user airdrop |
| `register_meter` | Device owner (user) | Link meter device to user account |
| `register_validator` | LA#2 or MEA/PEA aggregator (must have AggregatorEntry PDA) | Stake ≥ `MIN_VALIDATOR_STAKE` (10,000 GRX) as bond |
| `stake_grx` | Registered validator | Add to validator security bond (no yield) |
| `unstake_grx` | Registered validator | Begin unstake cooldown; blocked while Active |
| `slash_validator(severity_bps)` | Anyone on-chain (network-admitted) | Slash by `severity_bps`; partial → Suspended; full → Slashed |
| `aggregate_shards` | Admin (MEA/PEA/EGAT) | Reconcile 16-shard global totals |

**Sharding:** Hot-path writes target per-entity PDAs. Global counters sharded 16 ways: `shard = authority.to_bytes()[0] % 16`. Global totals stale by design; reconciled via `aggregate_shards`.

**Slash invariant:** `slash == compensation + fund`
- `compensation = min(slash, proven_loss)` → harmed party
- `remainder` → slash destination (ERC / consumer-rebate pool)

**Slash escape gap (open):** unstake-before-slash is possible if the validator unstakes before misbehaviour is detected. Fix: block unstake below `MIN_VALIDATOR_STAKE` while Active, or keep slashable regardless of status.

---

### 3.3 Oracle `64Vgos61STZ8p...` (impl)

**Purpose:** AMI gateway bridge; per-meter state; 15-minute clearing epochs.

| Instruction | Authority / Who Can Call | Description |
|---|---|---|
| `submit_meter_reading` | Chain Bridge (AggregatorBridge SPIFFE role) or admitted aggregator | Aggregator or Chain Bridge submits signed reading |
| `aggregate_readings` | Admitted aggregator (AggregatorEntry validated) | Aggregate readings into zone totals |
| `trigger_market_clearing` | Admitted aggregator | Fire clearing for a completed 15-min window |

`node-facing instructions` accept the Chain Bridge **or** an admitted aggregator (`AggregatorEntry` validated against Governance). The oracle does not call Governance via CPI — it deserializes and derives the `AggregatorEntry` PDA against `governance::ID` to authorize the caller.

---

### 3.4 Energy Token `6FZKcVKCLFSNLMx...` (impl)

**Purpose:** GRID (1 kWh = 1 GRID) and GRX SPL mints; REC-gated mint.

| Instruction | Authority / Who Can Call | Description |
|---|---|---|
| `mint_generation` | **AggregatorBridge SPIFFE role only** (MEA/PEA Aggregator Bridge) — BidEngine role (LA#2) CANNOT mint | Mint GRID from OBIS export; idempotent via `GenerationMintRecord` PDA |
| `mint_rec` | AggregatorBridge SPIFFE role + ERC co-sign for T-REC | Issue REC; requires admitted oracle validator co-sign |
| `transfer` | Token account owner | Standard SPL transfer (Token-2022 hooks) |

**Idempotency:** `GenerationMintRecord` PDA seeded by `[meter_id, register_reading, period]`. Re-submission is a no-op. This is the ultimate on-chain guard against double-mint.

**Mint authority restriction:** Private LA#2 operators hold the BidEngine SPIFFE role and are **not permitted** to call `mint_generation`. Only MEA/PEA running the Aggregator Bridge (AggregatorBridge SPIFFE role) may mint GRID tokens.

---

### 3.5 Trading `CnWDEUhTvSix...` (impl)

**Purpose:** Zone-scoped CDA order book; off-chain-signed match settlement; batch audit commitment.

| Instruction | Authority / Who Can Call | Description |
|---|---|---|
| `submit_order` | LA#2 BidEngine on behalf of participant; MEA/PEA via Bid Engine | Sharded order submit (shard by `authority.to_bytes()[0] % num_shards`) |
| `settle_offchain_match` | Admitted aggregator (AggregatorBridge or BidEngine role); **(gap: not yet enforced)** | Settle a match signed off-chain by the aggregator; requires admitted-aggregator signer |
| `record_settlement_batch` | Admitted aggregator via CPI to Treasury | Write `SettlementRecord` PDA (Merkle root + VAT + total) via CPI to Treasury |
| `cancel_order` | Order owner | Cancel an open order |

**Settlement gating gap:** `settle_offchain_match` is currently permissionless (no `is_operational` check, no admitted-aggregator signer requirement). Fix: add `governance_config` account + `is_operational()` guard + require admitted-aggregator signer.

**Wheeling charge gap:** distribution loss / wheeling charge is an unbounded caller argument. Fix: require tariff-authority signer; bound charge ≤ trade value.

---

### 3.6 Treasury `FfxSQYKUmx9NGd...` (impl)

**Purpose:** GRX ↔ THBG swap; reserve attestation; yield staking; settlement records.

| Instruction | Authority / Who Can Call | Description |
|---|---|---|
| `swap_grx_to_thbg` | Any network-admitted participant (with mTLS cert) | GRX → THBG at reserve-attested rate; bounded by `swap_vault` collateral |
| `redeem_thbg` | Any network-admitted participant | THBG → GRX redemption |
| `record_settlement_batch` | Trading program (via CPI from `settle_offchain_match`) | Write `SettlementRecord` PDA: `(zone, batch) → merkle_root + vat_amount + total_value` |
| `stake_grx` | Any network-admitted participant | Yield staking (MasterChef accumulator; separate from registry validator bond) |
| `update_attestation` | Reserve custodian (independent bank under BoT alignment) | Reserve custodian updates fiat-reserve proof |

**Peg invariant:** `total_thbg_supply ≤ reserve_attested_thbg`. Redemption bounded by `swap_vault` collateral + tracked supply.

**Two GRX staking systems (intentional):**
- `registry::stake_grx` — validator **security bond** (no yield; `MIN_VALIDATOR_STAKE`-gated; slashable)
- `treasury::stake_grx` — **yield staking** (MasterChef rewards from swap fees; separate vault/position)

---

## 4. Key PDAs

| PDA | Seed | Program | Purpose |
|---|---|---|---|
| `AggregatorEntry` | `[b"aggregator", authority]` | Governance | Zone operator / aggregator admission; checked by Oracle + DR Settlement |
| `UserAccount` | `[b"user", authority]` | Registry | User identity + validator bond |
| `MeterState` | `[b"meter", meter_pubkey]` | Oracle | Per-device reading state; 15-min window |
| `GenerationMintRecord` | `[b"gen_mint", meter, window]` | Energy Token | Idempotency key — prevents double-mint |
| `Order` | `[b"order", order_id]` | Trading | Open order in CDA book |
| `SettlementRecord` | `[b"settlement", zone, batch]` | Treasury | Merkle root + VAT + total (audit commitment) |
| `StakePosition` | `[b"stake", user]` | Treasury | Yield staking position |

---

## 5. Load-Bearing Invariants

1. **Zero-copy state.** Every hot-path struct is `#[account(zero_copy)] #[repr(C)]` + Pod with manual `_paddingN` for alignment. Use `AccountLoader`. Exception: `GenerationMintRecord` is regular `#[account]` (tiny idempotency marker, not hot-path).
2. **No `String` in zero-copy.** Use `[u8; N]` + `*_len: u8`.
3. **Sealevel parallelism.** Hot-path writes target per-entity PDAs — never global config. Global totals reconcile via admin instructions.
4. **`compute-debug` feature.** Each handler wraps body in `compute_fn!("label" => { ... })`; no-op in release. Preserve when adding instructions.
5. **`Clock::get()` before `emit!`** — hoist `let now = Clock::get()?.unix_timestamp;` before emitting events.
6. **Program ID changes** require `anchor keys sync` AND updating `declare_id!` in `lib.rs`.

---

## 6. Program IDs

Authoritative source: `gridtokenx-anchor/Anchor.toml` (localnet; matches each program's `declare_id!`). If the table below diverges, `Anchor.toml` wins.

| Program | ID |
|---|---|
| `energy-token` | `6FZKcVKCLFSNLMxypFJGU4K14xUBnxNW9VAuKGhmqjGX` |
| `governance` | `FokVuBSPXP11aeL7VZWd8n8aVAhWqVpyPZETToSxdvTS` |
| `oracle` | `64Vgos61STZ8pW9NnHi2iGtXMTQr7NqBoMorK6Zg8RJU` |
| `registry` | `FcSd5x4X1nzJMKLZC4tMZXnQ1ipLrGsEfeoH8N4mvJX7` |
| `trading` | `CnWDEUhTvSixeLSyViWgAnnu9YouBAYVGcrrFm1s9WcX` |
| `treasury` | `FfxSQYKUmx9NGdCC9TDPmZSYjWYE1h4ruu3JatzHN5Tn` |

---

## 7. Network Access

All six programs reside on a **private consortium SVM** — not public Solana mainnet. There is no public RPC endpoint. The Chain Bridge is the only application service with network access to the consortium RPC (:8899), and it requires mTLS client certificates. SPIFFE RBAC is enforced by the Chain Bridge before any instruction reaches the chain. No instruction from an unadmitted service can reach the blockchain.

See [`blockchain-node-network.md`](blockchain-node-network.md) for the full network access model and [`blockchain-service-mesh.md`](blockchain-service-mesh.md) for the service connection table.
