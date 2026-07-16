# Database-per-Service Migration

> Status: **Draft / in-progress** · Owner: platform · Last reviewed: 2026-07-15
> Target: move from the current **shared-database integration** anti-pattern to
> **physical database-per-service**, matching microservices best practice
> (each service owns its data; no cross-service SQL; cross-domain data flows via
> API reads + NATS event-carried state transfer).

---

## 1. Why

Today every Rust backend points `DATABASE_URL` at the pgdog pooler fronting **one
physical Postgres database, `gridtokenx`**. IAM's migrations are the de-facto
"god owner" of ~70 tables spanning four unrelated domains (identity, trading,
metering, carbon/vpp). Other services read — and in some cases **write** —
IAM-owned tables directly. This couples deploys, schemas, and failure domains:

- A trading schema change lives in IAM's migration history.
- Trading writes into IAM audit tables (`user_activities`, `wallet_audit_log`).
- Aggregator and Trading both join to identity tables for wallet resolution
  (and disagree on the source: `users.wallet_address` vs `user_wallets`).

Only two boundaries are clean today:
- **`gridtokenx_noti`** — Notification service already has its **own physical DB**
  (verified: pgdog `[[databases]] name="gridtokenx_noti"` with no
  `database_name` alias → maps to a real DB of that name). ✅ reference model.
- **chain-bridge** — owns `audit_log`, `dedup_effects` via its own migrations
  (target DB confirmation pending — see §4 TBD).

## 2. Target topology

One Postgres server (dev) / independent instances (prod) — one logical DB per service:

| DB | Owning service | Contains |
|----|----------------|----------|
| `gridtokenx_iam` | IAM | identity, wallets, keys, IAM audit, IAM outbox |
| `gridtokenx_trading` | Trading Service | orders, matches, settlements, epochs, futures, vpp, carbon, price alerts, trading outbox |
| `gridtokenx_meter` | Aggregator Bridge / meter-service | meter_readings, meter_registry, meters, oracle_submissions |
| `gridtokenx_chain` | Chain Bridge | audit_log, dedup_effects, blockchain_events* (TBD §4) |
| `gridtokenx_noti` | Notification | notifications, device_tokens (**done**) |

**Rule after migration:** no service issues SQL against another service's DB.
Cross-domain needs are met by:
- **Synchronous reads** → existing gRPC/REST (e.g. IAM `VerifyApiKey`, wallet lookup).
- **Data a service needs locally + often** → **event-carried state transfer**:
  the owning service emits domain events via its **outbox → NATS**; the consumer
  maintains a **local read-model table** in its own DB. Half-built already:
  `iam_outbox_events`, `outbox_events` tables + NATS infra exist.

## 3. Coupling map (verified by usage, not by migration author)

### 3.1 Trading Service — owns 14 tables

`trading_orders`, `settlements`, `order_matches`, `market_epochs`,
`recurring_orders`, `outbox_events`, `price_alerts`, `vpp_clusters`,
`vpp_cluster_members`, `futures_products`, `futures_orders`, `futures_positions`,
`carbon_credits`, `carbon_transactions` (+ their `*_archive` partitions).

**Cross-domain to unwind:**

| Site | Access | Foreign table | Fix |
|------|--------|---------------|-----|
| `crates/trading-infra/src/blockchain/rpc/service.rs:869` | READ | `user_wallets` (IAM) | local wallet read-model fed by IAM `user.wallet.*` events (or gRPC) |
| `crates/trading-persistence/src/repositories/vpp.rs:52,67` | JOIN | `meters` (metering) | local meter read-model fed by meter events |
| `crates/trading-infra/src/audit/mod.rs:50,140` | WRITE+READ | `user_activities` (IAM) | Trading owns its **own** `trading_user_activities` |
| `crates/trading-infra/src/blockchain/wallet/audit_logger.rs:122,172` | WRITE+READ | `wallet_audit_log` (IAM) | Trading owns its **own** wallet-audit table |

> Cross-domain **writes** (the two audit tables) are the hardest: DB-per-service
> forbids them. Cleanest resolution — audit is per-service; each service owns its
> own audit table. No event needed, just relocate the writes.

Trading ships **no migrations today** (`migrations/` holds only `.keep`). Phase 1
creates them.

### 3.2 Aggregator Bridge — owns `meter_readings`, small surface

| Table | Access | Site |
|-------|--------|------|
| `meter_readings` | WRITE (append-only INSERT…SELECT) | `crates/aggregator-persistence/src/infra/pg_readings.rs:183` |
| `meters` | READ (serial→user_id) | `pg_readings.rs:196`; `meter_registry.rs:119` |
| `users.wallet_address` | READ (user_id→wallet) | `pg_readings.rs:197`; `meter_registry.rs:119` |

Owner/wallet resolution already has a Redis hot cache
(`gridtokenx:meters:{serial}:user_id|:wallet`, `meter_registry.rs:149,157`) — the
local read-model is 80% there. `meter_registry`/`encryption_keys`/`api_keys` are
**not** read from Postgres (API-key auth is IAM gRPC; keys via Redis/Vault).
Non-Postgres backends (Redis, own InfluxDB, Kafka, NATS, SQLite buffer) already
isolated.

### 3.3 IAM — **uses only 4 tables** (verified)

Decisive result: of the ~70 tables IAM migrations create, IAM's **running code
touches only 4**, all identity-domain:

| table | R/W | site |
|-------|-----|------|
| `users` | R/W | `iam-persistence/src/repository/user.rs:83,111,133…` |
| `user_wallets` | R/W | `…/wallet.rs:59,157,87…` |
| `api_keys` | R/W | `…/api_key.rs:55,66` |
| `iam_outbox_events` | R/W | `…/outbox.rs:45,55,74` |

IAM issues **zero** cross-domain SQL. So `gridtokenx_iam` ends up **tiny** — the
other ~66 tables are pure migration-ownership artifacts to be reassigned to their
real user (Trading, metering, chain, or parked as orphan/dead). `meters` /
`notifications` matches in IAM `.rs` are false positives (doc-comment + a
`"meters:read"` permission string), not table access.

### 3.4 Chain Bridge — owns 3 tables (verified)

| table | R/W | site | migration |
|-------|-----|------|-----------|
| `dedup_effects` | R/W | `chain-bridge-persistence/src/dedup_store.rs:40,48,137` | `chain-bridge/migrations/0002_dedup_effects.sql` |
| `audit_log` | R/W | `…/postgres_audit.rs:94,111,138` | ⚠ created by **IAM** `20260620000000_add_chain_bridge_audit_log.sql` |
| `nonce_allocations` | R/W | `…/nonce_store.rs:36,39,69` | ⚠ **NO creating migration exists anywhere** |

Currently these live in the shared `gridtokenx` DB (only `gridtokenx` +
`gridtokenx_noti` exist on the server; `audit_log` present, `dedup_effects` not
created here). Chain-bridge issues zero cross-domain SQL.

**Two defects to fix during Phase 3:**
1. `nonce_allocations` — provisioning gap. `nonce_store.rs:3` claims "pre-seeded
   (see migrations/)" but no migration creates it. Add one to chain-bridge.
2. `audit_log` — move its `CREATE TABLE` out of IAM's migration set into
   chain-bridge's own migrations (an IAM-provisions-another-service artifact).

## 3.5 Resolved decisions (evidence-backed)

- **`rated_power_kw` / `rated_capacity_kwh` provenance → NONE (phantom).** These
  columns exist in **no** table (live DB), **no** migration, and **no** code except
  the `vpp.rs` SELECT itself. With `vpp_cluster_members` + `meters.rated_*` all
  phantom/drifted, the whole VPP-membership read is **dead code today** (would error
  `column does not exist`). Resolution: keep them **nullable** in `meter_read_model`
  (already are); the meter NATS feed leaves them NULL until meter-service adds
  ratings to its model. Post-split the query returns NULL instead of erroring —
  strictly better than today. Not a blocker; pre-existing defect.

- **`meters` ownership → meter-service** (sole writer, verified
  `gridtokenx-meter-service/crates/meter-persistence/src/repository/meter.rs`
  `INSERT INTO meters`). Aggregator only reads it.

- **Metering DB topology → ONE shared `gridtokenx_meter` for the metering bounded
  context** (meter-service **and** aggregator). Rationale: meter-service **owns**
  `meters`/`meter_registry` but also **reads** `meter_readings` (aggregator-owned),
  while the aggregator reads `meters` — bidirectional coupling inside one domain.
  Strict service-level split would need read-models in **both** directions; instead
  the two metering services share one DB (DB-per-bounded-context), each owning its
  own tables' migrations, still fully isolated from IAM/trading/chain/noti. This is
  the **one** deliberate exception to strict physical-DB-per-service. Table→owner
  inside `gridtokenx_meter`: meter-service owns `meters`, `meter_registry`,
  `meter_verification_attempts` (migrations move to meter-service); aggregator owns
  `meter_readings`(+partitions), `oracle_submissions`, `grid_status_history`,
  `meter_owner_read_model`.
  > Strict 2-DB alternative (`gridtokenx_meter` + `gridtokenx_readings`) remains
  > available if hard service-level isolation is required — cost: a readings
  > read-model on meter-service + a meters read-model on aggregator.

## 4. TBD / open questions (mostly resolved)

- ~~Chain-bridge target DB~~ → **`gridtokenx_chain`**; today shares `gridtokenx`.
- **`blockchain_events` / `blockchain_transactions` / `event_processing_state`** —
  created by IAM migration, used by **neither** IAM nor chain-bridge code. Orphan
  or external indexer. **Park** in Phase 3 (confirm no consumer, else assign).
- **Certificates/REC** (`energy_certificates`, `erc_certificate_transfers`) — no
  code user found; likely trading-domain future. Park with trading.
- **Identity-flavored but IAM-code-UNUSED** (`wallet_sessions`, `encryption_keys`,
  `wallet_audit_log`, `user_activities`, `outbox_events`): note `wallet_audit_log`
  + `user_activities` are **written by Trading** → they follow Trading, not IAM.
  `encryption_keys` (1 row) has no found code user — verify live before dropping.
- **Prod deployment** — separate Postgres *instances* per service, or one instance
  many DBs? (Failure-domain isolation vs ops cost.)

## 5. Phased plan (each phase independently shippable + tested)

Ordered by risk, lowest coupling first. **Noti already done.**

### Phase 1 — Trading → `gridtokenx_trading`
1. Author Trading migrations from the current live schema of its 14 tables
   (extract DDL from IAM migration history via `pg_dump --schema-only -t`).
2. Add `gridtokenx_trading` DB + pgdog `[[databases]]` route + least-priv role.
3. Relocate the two cross-domain **writes** → Trading-owned audit tables.
4. Replace `user_wallets` read + `meters` JOIN with local read-models fed by
   IAM/meter NATS events (bootstrap-backfill on first boot).
5. Cut `TRADING_DATABASE_URL` over to the new DB. Run `just e2e` + trading suite.

### Phase 2 — Metering → `gridtokenx_meter`
1. Move `meter_readings` (+ partitions), `meters`, `meter_registry`,
   `oracle_submissions` into aggregator-owned migrations + DB.
2. Promote the Redis wallet cache to a durable local read-model (NATS-fed).
3. Cut `AGGREGATOR_PG_READINGS` DB over. Verify ingest→mint hops.

### Phase 3 — Chain-bridge isolate + IAM trim
1. Confirm/park chain-bridge in `gridtokenx_chain`.
2. Delete reassigned tables from IAM migrations; IAM keeps identity/wallet/key
   + its outbox only.
3. Per-service DB roles: each login can touch **only** its own DB (revoke the rest).
4. Full-stack verify + update `ARCHITECTURE.md` topology + fix the misleading
   `docker-compose.yml:916` "schema" comment.

## 5b. Phase 1 — build status (as of 2026-07-15)

**Done (author-only, no running service touched, all reversible):**
- `gridtokenx_trading` DB created; both migrations applied + validated against real
  Postgres (30 tables, 19 enums, 179 indexes, 15 FKs, **zero cross-domain FK leak**).
- Read-model feeds built + `cargo check` green, all gated **OFF** by default:
  - Trading: `read_model.rs` repos + `read_model_feed.rs` worker + boot backfill,
    flag `TRADING_READMODEL_FEED` (off). Consumes a dedicated `FeedEvent{event_type,
    data}` (not the `Event` enum — JSON-incompatible).
  - IAM: `UserWalletLinked`/`UserOnboarded` payloads gain `is_primary` +
    `blockchain_registered`; new `UserWalletPrimaryChanged` emitted from
    `AuthService::set_primary_wallet`, routed to `user_events`.
  - meter-service: `MeterRegistered`/`MeterUpdated` Kafka emit (first publisher in
    that service), flag `METER_EVENTS_ENABLED` (off), topic `meter_events`.
- pgdog `gridtokenx_trading` + `_migrate` routes staged (inert until pgdog reload).
- Cutover runbook `scripts/db-split/phase1-trading-cutover.sh` (DRY_RUN=1 default;
  least-priv `trading_rw` role, FK-safe backfill, row-count parity, manual live steps).
- Fixed the misleading `docker-compose.yml` noti "schema" comment (it's a DB).

**Known follow-ups (non-blocking):**
- **`meter_read_model.status` semantics drift.** Backfill copies `meters.status`
  (operating: active/maintenance/…); the live `MeterRegistered` event derives status
  from `is_verified` (verified/unverified). Same column, two meanings — but no
  consumer reads `status` today (vpp.rs selects only `rated_*`). Unify when a
  consumer needs it: emit `meters.status` in the event, add a separate `is_verified`
  column if verification is also wanted.
- **`rated_power_kw`/`rated_capacity_kwh`** stay NULL (phantom source, §3.5).

**Not started — the atomic live cutover** (needs a maintenance window; steps 2–3
below couple code to the new tables so they can't precede the env flip): re-apply
audit repoint, swap the 2 read sites, reload pgdog, enable feeds + verify
read-models populate, freeze + backfill, flip `TRADING_DATABASE_URL`, `just e2e`.

## 5c. Pre-cutover checklist (plan review 2026-07-16)

Adversarial review of the plan before any live flip. ✅ = verified against code,
⚠️ = confirmed gap to handle, ☐ = must do per phase.

**Verified safe (no action):**
- ✅ **No cross-domain write transactions.** trading/aggregator never `INSERT/
  UPDATE/DELETE` foreign tables (`users`/`user_wallets`/`api_keys`/`meters`); all
  `pool.begin()` txns write only same-domain tables → atomicity preserved within
  each new DB. All cross-domain access was READ-only.
- ✅ **:4000/:4001 gateway is APISIX** — proxies to services, no `DATABASE_URL`,
  no direct DB access. Transparent to the split.

**Confirmed gaps — handle before/at cutover:**
- ⚠️ **(#6b) e2e DB-assertion coupling.** `tests/e2e/env.sh` +
  `tests/e2e/lib/db.py` connect directly to shared `gridtokenx`. DB-level e2e
  assertions will false-fail after data moves to the per-service DBs (HTTP/curl
  assertions — ~70 files — are split-resilient). ☐ Update `lib/db.py`/`env.sh` to
  resolve per-domain DBs, applied with each phase.
- ⚠️ **(#1) Revocation not evented.** IAM `DELETE FROM user_wallets ...
  is_primary=false` (`wallet.rs:112`) and meter decommission emit no delete event
  → read-models keep stale rows. *Low severity* (primary-wallet query filters
  `is_primary=true`). ☐ Add `UserWalletUnlinked`/`MeterDecommissioned` events or a
  periodic read-model reconcile before relying on read-models for delete-sensitive
  logic.
- ⚠️ **(#2) Event ordering.** Read-model last-writer-wins uses `updated_at=now()`
  (write time, not event time); `user_events` partitioning/keying unpinned. Out-of-
  order per-user wallet events could mis-set primary. *Low severity* (rare, heals on
  re-backfill). ☐ Key `user_events` by `user_id`, or stamp `updated_at` from the
  event timestamp.
- ☐ **(#4) pgdog routes.** Only `gridtokenx_trading` staged. Add
  `gridtokenx_meter`, `gridtokenx_iam`, `gridtokenx_chain` (+ `_migrate` aliases)
  before their phase flips.
- ☐ **(#5) Write-freeze / downtime.** Backfill is point-in-time with no dual-write
  → each flip needs a write freeze (or dual-write window) so writes between backfill
  and flip aren't lost. Plan the maintenance window accordingly.
- ⚠️ **(#8) Read-model feed test coverage.** Graph code-review flags the feed code
  as untested — trading `read_model.rs`/`read_model_feed.rs` (risk 0.85, elevated by
  the security-sensitive `WalletAuditLogger.log_operation` in the same diff) and
  aggregator `owner_read_model` backfill (risk 0.60). The feeds' correctness
  (last-writer-wins, sibling-demote of `is_primary`, event→upsert routing, idempotent
  backfill parity) rests on unverified code. ☐ Add docker integration tests (Kafka +
  Postgres) before production reliance. Also confirm `trading_wallet_audit_log`
  retention/columns match the IAM original before the wallet-audit write repoints.
- ⚠️ **(#9) Feeds interpret `is_primary`-absent OPPOSITELY** (surfaced by the feed
  unit tests). Trading's `WalletLinkedData.is_primary` is a bare `bool`
  (`#[serde(default)]` → **false** = non-primary); the aggregator's is `Option<bool>`
  (`None` → treated **primary**). Same wire event, opposite projection — harmless
  *only because IAM always emits an explicit `is_primary`*, but a latent divergence
  to unify. Related sharp edge: the aggregator's authoritative `update_wallet_by_user`
  writes NULL on a blank-wallet `Linked`/`Onboarded` event (blanks all a user's meter
  wallets), unlike the meter path's COALESCE-preserve — safe only while those events
  always carry a wallet (they do today).

**Phase 2 note:** the aggregator `meter_readings` sink uses `INSERT ... SELECT ...
JOIN users` — a cross-DB join that BREAKS after the split. Phase 2 cutover code
(not yet written) must swap that JOIN to `meter_owner_read_model`, same as Phase 1's
read-swaps (`db-split/phase1-cutover-code`).

## 6. Rollback / safety

- Each phase gated behind an env cutover (`*_DATABASE_URL`) — flip back to
  `gridtokenx` if verify fails.
- Dual-write window optional per phase (write old + new) before cutover.
- No phase deletes source tables until the new DB is verified in e2e.
- Backfill read-models from a snapshot on first boot, then keep current via NATS.
