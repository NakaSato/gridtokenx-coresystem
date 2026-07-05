# GridTokenX — Blockchain & Service Integration Tests

> Test reference for the Chain Bridge, NATS settlement pipeline, and consortium node connectivity.
> Covers what each test proves, how to run it, and what failure means.
> Last reviewed: June 2026

---

## Table of Contents

1. [Test Environment Setup](#1-test-environment-setup)
2. [Test Suite Structure](#2-test-suite-structure)
3. [Chain Bridge — gRPC Read Tests](#3-chain-bridge--grpc-read-tests)
4. [Chain Bridge — NATS Write Path Tests](#4-chain-bridge--nats-write-path-tests)
5. [Chain Bridge — RBAC & mTLS Tests](#5-chain-bridge--rbac--mtls-tests)
6. [Settlement Pipeline Tests](#6-settlement-pipeline-tests)
7. [Consortium Node Connectivity Tests](#7-consortium-node-connectivity-tests)
8. [Golden Path — Full Lifecycle Test](#8-golden-path--full-lifecycle-test)
9. [Rust Unit & Invariant Tests](#9-rust-unit--invariant-tests)
10. [Benchmark Tests](#10-benchmark-tests)
11. [Test Failure Reference](#11-test-failure-reference)

---

## 1. Test Environment Setup

### Prerequisites

All integration tests require infrastructure running. Start it in order:

```bash
# 1. Core infrastructure (Postgres, Redis, NATS, RabbitMQ, Kafka, Vault)
just orb-up

# 2. Consortium node (local single-node validator)
just solana-up                     # handles macOS Apple Silicon ulimit automatically

# 3. Deploy programs + seed accounts
./scripts/app.sh init              # deploys Anchor programs, seeds registry/shards

# 4. Verify all services are healthy
./scripts/app.sh doctor

# 5. Generate dev mTLS certificates (required for Chain Bridge auth tests)
just gen-certs                     # writes to infra/certs/
```

> **Re-seed without redeploying programs** (faster after validator ledger reset):
> ```bash
> just chain-reseed
> ```

### Environment Variables

Tests read these from the shell or `.env`:

| Variable | Default | Used By |
|---|---|---|
| `CHAIN_BRIDGE_GRPC` | `localhost:5040` | All Chain Bridge tests |
| `CHAIN_BRIDGE_HTTP` | `http://localhost:5040` | ConnectRPC tests |
| `CHAIN_BRIDGE_INSECURE` | `true` (dev) | mTLS mode detection |
| `NATS_URL` | `nats://localhost:4222` | NATS write path tests |
| `SOLANA_RPC_URL` | `http://localhost:8899` | Direct validator checks |
| `IAM_URL` | `http://localhost:4010` | Golden path tests |
| `AGGREGATOR_BRIDGE_REST` | `http://localhost:4030` | Settlement tests |
| `TRADING_URL` | `http://localhost:8093` | Golden path tests |
| `AGGREGATOR_API_KEY` | `engineering-department-api-key-2025` | Meter ingest |

### Python Test Dependencies

```bash
cd tests/e2e
pip install -r requirements.txt --break-system-packages

# or via uv (recommended)
uv run --no-project python -m pytest <suite> -v
```

### Run Modes

| Mode | Command | What runs |
|---|---|---|
| All E2E suites | `just e2e` | Suites 00–90 in sequence |
| Single suite | `just e2e-suite name="50_chain_bridge"` | Only that suite |
| Skip health gate | `SKIP_GATE=1 just e2e` | Useful when doctor is slow |
| Unit tests (service) | `cd gridtokenx-<service> && cargo test` | Rust unit tests |
| Anchor tests | `cd gridtokenx-anchor && anchor test` | On-chain program tests |
| Mainnet simulation | `just simnet` then `just e2e` | Full E2E on Surfpool |

---

## 2. Test Suite Structure

```
tests/e2e/
├── 00_harness/          Health gate — verify all services reachable before any test
├── 10_iam/              IAM registration, wallet provisioning, on-chain PDA creation
├── 20_oracle/           Meter ingest, Ed25519 verify, aggregation window
├── 30_settlement/       Mint exact delta, idempotency, surplus calculation, rejection
├── 40_trading/          CDA order matching, partial fills, trade lifecycle
├── 50_chain_bridge/     gRPC reads, NATS write path, RBAC, mTLS cert isolation
├── 60_noti/             Notification dispatch (email/push pipeline)
├── 70_anchor/           Anchor program integration (on-chain program logic)
├── 80_gateways/         APISIX routing, rate limiting, JWT enforcement
├── 90_golden_path/      Full lifecycle: register → meter → mint → trade → settle
├── lib/                 Shared helpers (assert.sh, crypto.py, nats_util.py, etc.)
└── run.sh               Orchestrator: health gate → suites → summary
```

Each suite runs independently. Later suites skip gracefully if their prerequisite service is unreachable. The test only **fails** if a reachable service produces a wrong result.

---

## 3. Chain Bridge — gRPC Read Tests

**Suite:** `tests/e2e/50_chain_bridge/test_chain_bridge.py` and `test_chain_reads.py`

**Transport:** ConnectRPC (HTTP POST + JSON — no proto codegen needed in Python).

### What is Tested

| Test | RPC Method | Assertion |
|---|---|---|
| `test_get_slot` | `GetSlot` | Returns `slot > 0`; proves validator is producing blocks |
| `test_get_latest_blockhash` | `GetLatestBlockhash` | Returns non-default hash; `lastValidBlockHeight > 0` |
| `test_get_balance` | `GetBalance` | System program returns `lamports >= 0`; schema valid |
| `test_get_account_data` | `GetAccountData` | System program (`111…`) account data returned; `executable = true` |
| `test_get_token_account_balance` | `GetTokenAccountBalance` | Returns `uiAmount` field |
| `test_get_prioritization_fees` | `GetRecentPrioritizationFees` | Returns array (may be empty on localnet) |
| `test_get_epoch_info` | `GetEpochInfo` | Returns `epoch`, `absoluteSlot`, `slotsInEpoch` |
| `test_get_signature_status` | `GetSignatureStatus` | Default signature → `null` status (not found); no panic |
| `test_request_airdrop` | `RequestAirdrop` | Localnet only; confirms airdrop lands; skipped on mainnet |
| `test_nats_status` | `chain.tx.status` NATS subject | Reply arrives on `chain.tx.statusresult.{cid}`; result schema valid |

### How to Run

```bash
cd tests/e2e
python -m pytest 50_chain_bridge/test_chain_bridge.py -v
python -m pytest 50_chain_bridge/test_chain_reads.py -v
```

### Expected Output (pass)

```
test_get_slot                    PASSED  slot=1542
test_get_latest_blockhash        PASSED  hash=ABC...
test_get_balance                 PASSED  lamports=1
test_get_account_data            PASSED  executable=True
test_get_epoch_info              PASSED  epoch=0 absoluteSlot=1542
test_get_signature_status        PASSED  status=null (not found — expected)
test_request_airdrop             SKIPPED (mainnet — no airdrop)
test_nats_status                 PASSED  reply received in 2.1s
```

### Failure Meaning

| Failure | Likely Cause |
|---|---|
| `test_get_slot` fails | Validator not running (`just solana-up`) |
| `test_get_latest_blockhash` fails | Chain Bridge cannot reach RPC node |
| Any read returns wrong schema | Chain Bridge proto version mismatch |
| `test_nats_status` timeout | NATS not running or Chain Bridge NATS consumer not started |

---

## 4. Chain Bridge — NATS Write Path Tests

**Suite:** `tests/e2e/50_chain_bridge/test_nats_tx.py`

### What is Tested

This suite proves the **full async write pipeline**: publish to NATS → Chain Bridge consumes → Vault signs (insecure dev keypair in local) → submits to consortium node → confirms landed.

| Test | Subject | Assertion |
|---|---|---|
| `test_submit_tx` | `chain.tx.submit` | Reply on `chain.tx.result.{cid}`: `success=true`, non-empty `signature` (base58), and the signature is **actually queryable on the validator** (landed, not just accepted) |
| `test_submit_dedup` | `chain.tx.submit` (same idempotency_key twice) | Second publish replays result without double-submitting; `send_count` on validator does NOT increase |

### Envelope Construction Requirements

The test hand-builds a valid Solana transaction to send over NATS. These constraints come directly from the Chain Bridge implementation:

```python
envelope = {
    "instruction":     "settle_p2p_trade",          # or any allow-listed instruction
    "key_id":          "platform_admin",            # MUST be exactly this string
    "accounts":        [...],
    "data":            base64(instruction_bytes),
    "idempotency_key": str(uuid.uuid4()),
    "submitted_by":    "trading-service",
    "correlation_id":  nats_msg_id,
}

# Transaction constraints:
# fee_payer = SOLANA_PAYER_KEY (EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ) in dev
# includes ComputeBudget SetComputeUnitLimit instruction (always allow-listed by policy)
# uses a real recent blockhash (fetched via Chain Bridge GetLatestBlockhash)
```

**NATS envelope auth** (required when `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true`):

```python
# Sign envelope bytes with the service's mTLS client key (P256/SHA-256)
auth = envelope_auth.sign(envelope_bytes, client_key_path)
envelope["auth"] = auth
envelope["service_identity"] = "spiffe://gridtokenx.th/prod/trading-service"
```

### How to Run

```bash
cd tests/e2e
python -m pytest 50_chain_bridge/test_nats_tx.py -v -s
```

### Expected Output (pass)

```
test_submit_tx       PASSED  signature=4xK...  landed_slot=1588
test_simulate_tx     PASSED  success=true  no signature (correct)
test_submit_dedup    PASSED  second publish → replayed result (1 on-chain tx total)
```

### Failure Meaning

| Failure | Likely Cause |
|---|---|
| `test_submit_tx` timeout (no reply) | NATS consumer not running; wrong subject |
| `success=false` in result | `key_id` not `platform_admin`; fee_payer mismatch; stale blockhash |
| `signature` not found on validator | Transaction landed but validator reset since |
| `test_submit_dedup` shows 2 txs | `claim_or_replay` dedup broken |
| Auth rejection (401) | Envelope not signed or wrong client key |

---

## 5. Chain Bridge — RBAC & mTLS Tests

**Suite:** `tests/e2e/50_chain_bridge/test_chain_bridge.py` (mTLS isolation cases)

### What is Tested

| Test | Mode | Assertion |
|---|---|---|
| `test_role_admin_reads` | Header auth or mTLS admin cert | All read RPCs succeed |
| `test_role_unknown_rejected` | No cert, no header | gRPC status `UNAUTHENTICATED` or `PERMISSION_DENIED` |
| `test_role_wrong_cert_rejected` | Client cert for wrong service | Read rejected for write instructions |
| `test_mtls_wrong_ca_rejected` | Cert signed by unknown CA | TLS handshake failure (connection refused) |
| `test_spiffe_san_required` | Cert without SPIFFE SAN | Mapped to `ServiceRole::Unknown` → rejected |

### mTLS Detection Logic

Tests auto-detect whether mTLS is active:

```python
MTLS = (
    CA.is_file()                                   # ca.crt exists (just gen-certs was run)
    and (CLIENTS / "admin.crt").is_file()          # admin client cert exists
    and os.getenv("CHAIN_BRIDGE_INSECURE") != "true"  # bridge is not in insecure mode
)
```

When `CHAIN_BRIDGE_INSECURE=true` (default dev), mTLS isolation tests are skipped — they require proper TLS mode.

### How to Run (mTLS mode)

```bash
just gen-certs                          # generate CA + client certs
CHAIN_BRIDGE_INSECURE=false \
CHAIN_BRIDGE_ALLOW_HEADER_AUTH=false \
python -m pytest 50_chain_bridge/test_chain_bridge.py -v -k "mtls"
```

### Client Certificate Paths (from `just gen-certs`)

```
infra/certs/
├── ca.crt                    # Root CA (verify server cert against this)
├── chain-bridge.crt          # Server cert
├── chain-bridge.key
└── clients/
    ├── admin.crt             # Full-access client (dev only)
    ├── admin.key
    ├── aggregator-bridge.crt # ServiceRole::AggregatorBridge
    ├── trading-service.crt   # ServiceRole::TradingService
    └── ...
```

---

## 6. Settlement Pipeline Tests

**Suite:** `tests/e2e/30_settlement/`

These tests prove the meter-reading → aggregation → NATS mint envelope → Chain Bridge → on-chain token mint pipeline.

### Test: Exact Mint Delta (`test_mint_exact_delta.py`)

**What it proves:** The minted amount exactly equals the net surplus kWh — not gross generation, not consumption alone.

| Case | Setup | Expected mint `energy_kwh` |
|---|---|---|
| A — clean surplus | Generated=40, Consumed=0 | `40.0` |
| B — mixed gen/consume | Generated=30, Consumed=12 | `18.0` (net surplus only) |

**Key invariant checked:**

```
round(energy_kwh × 1e9) == expected_atomic_units
    (GRID has 9 decimals; kWh → atomic units conversion pinned here)
```

**How to Run:**

```bash
cd tests/e2e
python -m pytest 30_settlement/test_mint_exact_delta.py -v -s
```

**Slow by design:** the aggregation window (15 min) must close before the flush loop fires. Tests use backdated timestamps to force window closure. Allow ~30s per case.

---

### Test: Settlement Idempotency (`test_settlement_idempotency.py`)

**What it proves:** Submitting the same `(meter_id, window)` twice produces **one** on-chain mint — not two. The `idempotency_key` format `mint:{serial}:{window_start_ms}` is stable across replays.

**Assertion (NATS-level observation):**

```python
# Send same serial into same closed window twice
mint_messages = observe_nats("chain.tx.mint", timeout=MINT_WAIT)

# ALL observed messages for this (serial, window) share one idempotency_key
keys = {m["idempotency_key"] for m in mint_messages if m["serial"] == serial}
assert len(keys) == 1, "idempotency_key drifted — double-mint risk"

# All share same window_start_ms and energy_kwh
assert all_same(m["window_start_ms"] for m in mint_messages)
assert all_same(m["energy_kwh"] for m in mint_messages)
```

> **Note:** The on-chain `GenerationMintRecord` PDA is the ultimate double-mint guard. The `idempotency_key` assertion here verifies the NATS-layer contract that feeds the PDA.

**Skip semantics:** if no mint arrives within `MINT_WAIT`, the test **SKIPS loudly** (never silently passes). A silent pass would hide a disabled mint pipeline.

---

### Test: Unregistered Meter Rejected (`test_unregistered_meter_rejected.py`)

**What it proves:** A reading from a meter with no registered Ed25519 pubkey in Redis is dropped — never reaches the settlement pipeline. Fail-closed on unknown device.

```python
# Send signed reading with unknown device key
response = post_meter_reading(serial="UNKNOWN-9999", signature=random_sig)
assert response.status_code == 401   # or 400 — not 200
# No mint envelope appears on NATS for this serial
```

---

### Test: Aggregation Window (`tests/e2e/20_oracle/test_aggregation_window.py`)

**What it proves:** Multiple readings within the same 15-minute window are aggregated into one bin; readings in different windows produce separate bins.

**Assertions:**

```python
# 3 readings in same window → one mint envelope with summed energy_kwh
# 1 reading in next window → separate mint envelope
assert len(mint_envelopes) == 2      # two windows → two mints
assert mint_envelopes[0]["energy_kwh"] == sum_of_window_1_kwh
assert mint_envelopes[1]["energy_kwh"] == reading_in_window_2_kwh
```

---

## 7. Consortium Node Connectivity Tests

These tests verify that Chain Bridge can reach the consortium RPC node and that the node is producing blocks correctly.

### Health Check Tests

```bash
# Verify all services reachable (runs as part of e2e health gate)
./scripts/app.sh doctor

# Verify Chain Bridge → RPC → validator chain
just verify-conns
```

`verify-conns` probes in order: Postgres → Redis → Chain Bridge → NATS → IAM → Kafka.

### Manual Node Health Checks

```bash
# Verify validator is producing blocks
curl http://localhost:8899 -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}'
# Expected: { "result": <slot_number> }

# Verify slot is advancing (run twice, 2s apart)
SLOT1=$(curl -s http://localhost:8899 -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}' | jq .result)
sleep 2
SLOT2=$(curl -s http://localhost:8899 -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}' | jq .result)
echo "Slot advanced: $SLOT1 → $SLOT2"
# Expected: SLOT2 > SLOT1

# Verify blockhash is fresh (not default all-zeros)
curl http://localhost:8899 -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getLatestBlockhash"}'
# Expected: { "result": { "value": { "blockhash": "<non-zero-hash>", ... } } }
```

### Chain Bridge Connectivity Test

```python
# From test_chain_bridge.py — GetSlot is the minimal connectivity check
def test_get_slot():
    r = connect_call("GetSlot", {})
    assert r.status_code == 200
    data = r.json()
    assert "slot" in data
    assert data["slot"] > 0       # validator is producing blocks
```

### Consortium Multi-Node Test (Staging / Production)

For the consortium cluster (not local dev), verify each utility node is voting:

```bash
# Check validator vote accounts (run from a node that can reach gossip port)
solana validators --url <consortium-rpc-url>

# Expected: EGAT node, MEA node, PEA node all listed as "Current" with recent votes
# Red flag: any node shows "Delinquent" → that utility's node is offline
```

**Fault threshold check:**

```bash
# Count active validators
ACTIVE=$(solana validators --url <rpc> --output json | jq '[.validators[] | select(.delinquent == false)] | length')
TOTAL=$(solana validators --url <rpc> --output json | jq '.validators | length')

echo "Active: $ACTIVE / $TOTAL"
# If ACTIVE < ceil(TOTAL * 2/3): network is degraded (approaching halt threshold)
# If ACTIVE < ceil(TOTAL / 3) + 1: network will halt
```

---

## 8. Golden Path — Full Lifecycle Test

**Suite:** `tests/e2e/90_golden_path/test_golden_path.py`

The golden path chains every system hop end-to-end. It is the **regression anchor** — if this passes, the full settlement lifecycle works.

### Lifecycle Steps

```
Step 1   Register user A (seller) + user B (buyer) via IAM
              → wallet provisioned (Vault key)
              → on-chain UserAccount PDA created (Registry program)

Step 2   Register seller's smart meter
              → device Ed25519 pubkey → Redis
              → meter → user mapping → Redis

Step 3   Send backdated signed GENERATION readings (DLMS/COSEM format)
              → Aggregator Bridge verifies Ed25519 signature
              → reading enters 15-min aggregation window

Step 4   Wait for settlement window close
              → Aggregator Bridge flushes bin
              → NATS chain.tx.submit published (mint_generation)
              → Chain Bridge: RBAC → dedup → Vault sign → consortium RPC
              → GenerationMintRecord PDA created (exactly-once guard)
              → GRID tokens minted to seller wallet

Step 5   Seller submits SELL order via Trading Service
              → CDA engine accepts order

Step 6   Buyer submits crossing BUY order
              → CDA engine matches → fills
              → Trade record created

Step 7   Settlement (best-effort — asserted only if Chain Bridge reachable)
              → NATS chain.tx.submit (settle_p2p_trade)
              → GRID tokens: buyer → seller
              → REC minted to seller wallet

Step 8   Notification dispatched (best-effort)
              → RabbitMQ → Noti Service → email/push

Step 9   Liveness checks
              → Chain Bridge slot advances between first and last check
              → Explorer HTTP reachable (if configured)
```

### How to Run

```bash
cd tests/e2e
python -m pytest 90_golden_path -v -s
# or
just e2e-suite name="90_golden_path"
```

### Pass / Skip / Fail Semantics

| Outcome | Meaning |
|---|---|
| `PASSED` | All reachable stages produced correct results |
| `SKIPPED` | A prerequisite service was unreachable; that stage was not tested |
| `FAILED` | A reachable service produced a wrong result |

The test **does not fail** if Settlement or Notification is unreachable (those stages are marked best-effort). It **does fail** if IAM is unreachable — IAM is the hard prerequisite for the entire scenario.

### Expected Output (full pass)

```
test_golden_path   PASSED

  ✅ IAM healthy
  ✅ seller registered (email: seller@e2e.test)
  ✅ buyer registered  (email: buyer@e2e.test)
  ✅ seller wallet provisioned
  ✅ seller PDA on-chain
  ✅ meter registered (serial: E2E-METER-001)
  ✅ 3 readings ingested
  ✅ mint envelope observed on NATS (energy_kwh=5.0)
  ✅ SELL order submitted (id: ord-xxx)
  ✅ BUY order matched → trade filled (id: trd-yyy)
  ✅ settlement tx submitted to chain
  ✅ slot advanced: 1500 → 1612
  ⚠ noti service unreachable — notification stage SKIPPED
```

---

## 9. Rust Unit & Invariant Tests

### Chain Bridge Invariant Tests

**File:** `gridtokenx-chain-bridge/crates/chain-bridge-api/tests/invariants.rs`

These are Rust integration tests asserting the Chain Bridge's **safety and liveness properties** using mock providers — no real network required.

```bash
cd gridtokenx-chain-bridge
cargo test                              # all unit + invariant tests
cargo test test_dedup -- --nocapture   # dedup/idempotency invariant
cargo test test_rbac  -- --nocapture   # RBAC role enforcement
```

**Key invariants tested:**

| Test | Invariant |
|---|---|
| `test_dedup_claim_or_replay` | Submitting same `idempotency_key` twice → second returns replayed result; `MockSolanaProvider::send_count == 1` |
| `test_rbac_unknown_role_rejected` | `ServiceRole::Unknown` → `PERMISSION_DENIED` on any write instruction |
| `test_rbac_wrong_role_for_instruction` | `TradingService` role cannot call `mint_generation` |
| `test_vault_key_id_enforced` | Any `key_id != "platform_admin"` → rejected (does not reach Vault) |
| `test_blockhash_cache_served` | `sign_and_submit` reads from cache; `get_latest_blockhash` RPC not called on hot path |
| `test_nats_optional_at_startup` | NATS connect failure → service starts in gRPC-only mode (no panic) |

### Aggregator Bridge Unit Tests

```bash
cd gridtokenx-aggregator-bridge
cargo test                              # all unit tests
cargo test crypto -- --nocapture       # Ed25519 verify + AES-256-GCM decrypt
cargo test settlement -- --nocapture   # 15-min window aggregation logic
```

**Key tests:**

| Test | What it covers |
|---|---|
| `test_ed25519_verify_pass` | Valid signature + correct pubkey → accepted |
| `test_ed25519_verify_fail_closed` | Invalid signature → dropped (fail-closed) |
| `test_ed25519_redis_down_fail_closed` | Redis unreachable → dropped (not trusted by fallback) |
| `test_aes_gcm_decrypt_valid` | Valid ciphertext + known enckey → plaintext |
| `test_aes_gcm_wrong_key_rejected` | Wrong enckey → decryption error, payload dropped |
| `test_window_aggregation` | 3 readings same window → one bin, summed kWh |
| `test_window_boundary` | Reading at window boundary → correct window assignment |
| `test_net_surplus_positive_only` | Consumed > Generated → no mint (surplus = 0, not negative) |

### Anchor Program Tests

```bash
cd gridtokenx-anchor
anchor test                             # all on-chain program tests (spawns local validator)

# Individual program test files (TypeScript / Bankrun LiteSVM)
npm run test:governance                 # governance.ts
npm run test:all                        # all programs
```

**Key settlement-related tests:**

| File | What it covers |
|---|---|
| `generation_mint_idempotency.ts` | Same `(meter, window)` → `GenerationMintRecord` PDA blocks second mint |
| `batch_settle_thbg.ts` | `record_settlement_batch` writes `SettlementRecord` PDA with correct Merkle root + VAT |
| `energy_token_rec_guards_litesvm.ts` | REC mint gated on admitted aggregator `AggregatorEntry` |
| `escrow_settlement.ts` | P2P atomic settlement; `settle_offchain_match` CU benchmark |
| `governance_authority_guards_litesvm.ts` | Unauthorized callers rejected on `admit_aggregator`, `revoke_aggregator` |

---

## 10. Benchmark Tests

These measure performance characteristics, not correctness.

### Settlement Compute Units (`just bench-settlement`)

Measures on-chain compute units consumed by `settle_offchain_match`. The meaningful metric is CU cost — not localnet latency.

```bash
just bench-settlement
# Grep output for: BENCH_SETTLE_CU=<number>
# Expected range: 3,000 – 20,000 CU (well under 200k default / 1.4M max)
```

Requires: Anchor + local validator (or Surfpool `just simnet`).

### Telemetry Ingest Saturation (`just bench-ingest`)

Ramps meter load and measures Aggregator Bridge throughput and loss rate. Does NOT require Solana validator — only bridge + Redis.

```bash
just orb-up
just bench-ingest
# Tune via: RAMP=<meters_per_step> DURATION=<seconds> INTERVAL=<ms> REPEATS=<n>

# Summarize results
python scripts/bench-ingest-summary.py bench-ingest-results.csv
```

**Metrics reported:**

| Metric | Meaning |
|---|---|
| `throughput_msg_per_sec` | Readings processed per second |
| `loss_rate_pct` | % readings dropped (signature fail or backpressure) |
| `p99_ingest_latency_ms` | 99th percentile time from receive to Redis stream write |

### Trading Engine (`just benchmark`)

CDA matching engine benchmark. No infrastructure required — pure computation.

```bash
just benchmark
# Criterion output: matching throughput orders/sec, latency distribution
```

---

## 11. Test Failure Reference

### Chain Bridge

| Failure | Root Cause | Fix |
|---|---|---|
| `GetSlot` returns error | Validator not running | `just solana-up` |
| All reads timeout | Chain Bridge not started | `cargo run -p gridtokenx-chain-bridge` |
| Submit returns `success=false` | `key_id` is not `platform_admin` | Check envelope construction |
| Submit returns `success=false` (fee payer) | Transaction fee payer ≠ `SOLANA_PAYER_KEY` | Set fee payer to dev keypair pubkey |
| Dedup test: 2 transactions land | `claim_or_replay` regression | Check `idempotency_key` uniqueness |
| mTLS test: connection refused | Bridge in insecure mode | `CHAIN_BRIDGE_INSECURE=false` |
| mTLS test: cert rejected | Wrong CA or SPIFFE SAN missing | `just gen-certs` (regenerate) |
| NATS test: no reply | Consumer not subscribed | Verify `NATS_URL`; check bridge logs for "NATS path disabled" warning |

### Settlement Pipeline

| Failure | Root Cause | Fix |
|---|---|---|
| No mint envelope (SKIP) | Mint pipeline disabled or window not closed | Verify `MINT_VIA_CHAIN_BRIDGE=true`; wait for window |
| `energy_kwh` wrong | Net surplus calculation bug | Check `test_net_surplus_positive_only` Rust unit test |
| `idempotency_key` drifts between replays | Key construction bug in Aggregator Bridge | Check `infra/mint.rs` key format `mint:{serial}:{window_start_ms}` |
| Unregistered meter not rejected | Ed25519 verify not fail-closed | Verify Redis has no stale pubkey; check bridge crypto unit test |

### Consortium Node

| Failure | Root Cause | Fix |
|---|---|---|
| `getSlot` returns stale slot | Validator halted (< 2/3 nodes voting) | Restore offline nodes |
| `getLatestBlockhash` returns default hash | RPC not connected to validator | Check `SOLANA_RPC_URL` |
| `sendTransaction` rejected | Stale blockhash (> 150 slots old) | Verify `BlockhashCache` refresh is running (every 2s) |
| Golden path mint not landed | Programs not deployed | `./scripts/app.sh init` |
| `GenerationMintRecord` PDA already exists | Re-init without clearing ledger | `just solana-down && just solana-up && ./scripts/app.sh init` |

---

*GridTokenX Blockchain & Service Integration Tests — v1.0 — June 2026*
*See also: [blockchain-node-network.md](../blockchain-node-network.md) · [blockchain-system.md](../blockchain-system.md) · [ARCHITECTURE.md](../../ARCHITECTURE.md)*
