---
name: telemetry-hops
description: Run and verify the end-to-end telemetry data-hop chain — meter onboard (IAM register→verify→claim) → signed DLMS/COSEM ingest into the Aggregator Bridge → owner+wallet resolve → zone Redis stream → 15-min settlement bin → surplus mint over NATS chain.tx.mint → Solana. Use when the user says "hops test", "run the hops", "test telemetry path", "test the mint", "force a surplus", "verify settlement/mint", or wants any leg of the meter→bridge→settlement→chain pipeline exercised and verified hop-by-hop. Drives the live docker stack (compose up). Confirms each trust gate with real log/DB/Redis evidence — never assumes success.
---

# Telemetry Hops — end-to-end run & verify

Exercises the full Path-A telemetry pipeline against the **live docker stack** and
verifies **each hop with real evidence** (logs / Postgres / Redis), per the repo's
test-first rule. Never report a hop green without its citation.

## Preconditions

Stack up (`docker ps` healthy): `iam-service`, `meter-service`, `aggregator-bridge`,
`chain-bridge`, `postgres`, `redis`, `nats`. Validator native on host for the mint leg.
If down: `just orb-up` (infra) + validator per `[[validator-reset-onchain-init]]`.

**Live ports (verified — do NOT trust script defaults):**

| Service | Host port | Note |
|---|---|---|
| IAM HTTP | `4010` | container 8080; script default `4013` is WRONG |
| meter-service | `4062` | owns `POST /api/v1/meters` (NOT IAM) |
| aggregator-bridge ingest | `4030` | `/v1/private-network/ingest` |
| chain-bridge | `5040` | NATS mint consumer + Solana RPC |
| redis | `7010` | device registry + owner/wallet cache + zone streams |
| postgres | `7001` | `meters`/`users` durable owner+wallet source |

Confirm IAM port if unsure: `docker port gridtokenx-iam-service`.

## The hop chain (trust gates — each can drop the reading)

```
onboard:  IAM register 200 → verify 200 (auto-provisions custodial wallet → users.wallet_address)
          → login 200 (JWT) → meter-service POST /api/v1/meters 200 (writes meters.user_id)
stream:   sim signs device_id:kwh:ts_ms (Ed25519) → POST /ingest (X-API-KEY)
  [1] api_key_auth      X-API-KEY            else 401
  [2] verify signature  Ed25519 vs Redis pubkey   else reject
  [3] owner resolve     meter_owner_read_model / user_wallet_read_model  else bin EVICTED
  [4] disseminate       zone Redis stream + InfluxDB + Kafka + settlement bin
settle:   15-min bin (gen-cons>0 = surplus) → sweep (interval 30s, grace 120s)
mint:     net_surplus_kwh → resolve_wallet → NATS chain.tx.mint → chain-bridge → Solana sim → sign
```

## Run mode A — full IAM-backed e2e (owner attribution, no surplus)

`:4030` (→ container `:4010`) **always** terminates TLS (`docker-compose.yml:809`,
independent of `AGGREGATOR_REQUIRE_SECURE`) — use `https://`, never `http://`. Plaintext
against this port doesn't 4xx cleanly, it garbles the response and httpx throws
`illegal request line`.

`AGGREGATOR_API_KEY` is **required** — the client passes `api_key=config.aggregator_api_key`
(`e2e_iam_flow.py:227`, that regression is fixed) but the setting defaults to `""`, so
omitting it is a silent 401.

```bash
cd gridtokenx-smartmeter-simulator/backend
AGGREGATOR_DLMS_ENABLED=true AGGREGATOR_BRIDGE_URL=https://localhost:4030 \
AGGREGATOR_API_KEY=engineering-department-api-key-2025 \
REDIS_URL=redis://localhost:7010 \
  uv run python scripts/e2e_iam_flow.py --meters 1 --once --iam-url http://localhost:4010
```

Expect: register/verify/login 200 · claim 200 (`claimed=True`) · script auto-loads the dev
mTLS client cert (`https bridge: using dev mTLS client cert ...`) · ingest **202** ·
sent=1 failed=0 — **unless** this stack has `AGGREGATOR_REQUIRE_SECURE=true`, in which
case plain REST ingest gets a clean **426 Upgrade Required** (expected, not a bug) — switch
to `--encrypt` per the secure-stack block in Run mode B.

> If claim 404 → it's POSTing to IAM not meter-service (stale script); if ingest 401 →
> `AggregatorBridgeClient` built without `api_key=config.aggregator_api_key`. Both are
> known regressions in `e2e_iam_flow.py` — patch per the hop map above.

## Run mode B — force a surplus & watch the mint fire

Use the bundled helper. It signs a backdated `+N kWh` reading into an **already-completed**
15-min window so the settlement sweep evicts it within ~30s (no 16-min wait). Pass a meter
serial already claimed via mode A (so it has an owner+wallet).

```bash
cd gridtokenx-smartmeter-simulator/backend
AGGREGATOR_BRIDGE_URL=http://localhost:4030 REDIS_URL=redis://localhost:7010 \
  uv run python "$CLAUDE_PROJECT_DIR/.claude/skills/telemetry-hops/scripts/force_surplus.py" \
    --meter <SERIAL> --kwh 5 --zone 4
```

> **Secure stack (`AGGREGATOR_REQUIRE_SECURE=true`)**: plaintext REST is refused with
> **426**. Use an **https** URL + `--encrypt` — it seals the frame as an AES-256-GCM
> `dlms-enc` envelope (registers the device enckey, monotonic counter) and auto-presents
> the dev mTLS client cert from `infra/certs/clients/`. The api key must validate against
> IAM (`just check-apikey`; `just seed-apikey` to repair drift). Proven end-to-end on the
> hardened stack (encrypted ingest 202 → settlement → mint on-chain).
> ```bash
> AGGREGATOR_BRIDGE_URL=https://localhost:4030 \
> AGGREGATOR_API_KEY=engineering-department-api-key-2025 REDIS_URL=redis://localhost:7010 \
>   uv run python "$CLAUDE_PROJECT_DIR/.claude/skills/telemetry-hops/scripts/force_surplus.py" \
>     --meter <SERIAL> --kwh 5 --zone 4 --encrypt
> ```
> If the validator was TTL-reaped, the signed mint stays in the durable outbox; restart it
> with `just solana-up-keep` (preserves ledger, no auto-kill) and the outbox drains on-chain.

Then poll for the mint (~30–40s, two sweeps):

```bash
for i in $(seq 1 4); do
  docker logs gridtokenx-aggregator-bridge --since 90s 2>&1 | grep <SERIAL> | grep -iE "mint|surplus|⚡" && break
  sleep 12
done
docker logs gridtokenx-chain-bridge --since 90s 2>&1 | grep -iE "mint|simulation|Custom|⚡|slot"
```

## Per-hop verification (cite evidence)

```bash
S=<SERIAL>
# [2] signature + [4] zone dissemination
docker logs gridtokenx-aggregator-bridge --since 60s 2>&1 | grep "$S" | grep -E "signature verified|Disseminated"
# [3] owner+wallet — the aggregator resolves from READ MODELS, never a JOIN.
# `meters` lives in gridtokenx_meter and `users` in gridtokenx_iam (DB-per-service),
# so the old `-d gridtokenx ... meters JOIN users` query cannot run: that database
# contains NEITHER table. Check the projections the resolver actually reads:
docker exec gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx_meter -tAc \
  "SELECT serial_number, user_id, wallet_address FROM meter_owner_read_model WHERE serial_number='$S'"
docker exec gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx_meter -tAc \
  "SELECT user_id, wallet_address FROM user_wallet_read_model WHERE user_id='<USER_UUID>'"
# Source of truth to compare against (two different databases):
docker exec gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx_meter -tAc \
  "SELECT serial_number, user_id FROM meters WHERE serial_number='$S'"
docker exec gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx_iam -tAc \
  "SELECT id, wallet_address FROM users WHERE id='<USER_UUID>'"
# [4] full OBIS register set in zone stream (zone N)
docker exec gridtokenx-redis redis-cli XREVRANGE gridtokenx:events:zone_4 + - COUNT 1
# settle + mint
docker logs gridtokenx-aggregator-bridge --since 120s 2>&1 | grep -iE "billing bin|flushed .* bin|minted|mint skipped|mint failed"
```

## Decoding a mint failure

`pre-sign simulation failed: InstructionError(2, Custom(6000))` → Anchor error, **instruction
index 2** (after 2 compute-budget ix), first custom variant `6000` of the program being called.
For the energy-token mint that's `EnergyTokenError::UnauthorizedAuthority`
(`energy-token/src/lib.rs:121`): on-chain `token_info.authority` ≠ chain-bridge mint signer.
Reconcile per `[[validator-reset-onchain-init]]` (set energy-token authority to the bridge
signer, or point bridge at the matching keypair). Custom codes are program-relative — map
`6000+n` to the n-th variant of the program at that instruction's `error.rs`.

## `no registered owner` — the read-model projection is dead

```
surplus mint skipped: meter <S> has no registered owner (window …) — bin evicted, not enqueued
```

**This is not the same class of failure as a failed mint.** A failed mint stays in the
durable outbox and drains later; an unresolved owner **evicts the bin**, so the metered
energy is destroyed with nothing to replay. Every meter onboarded while the projection is
stale loses its surplus permanently and silently.

Both projections (`meter_owner_read_model`, `user_wallet_read_model`, in `gridtokenx_meter`)
are built by the aggregator's `OwnerReadModelConsumer`
(`crates/aggregator-persistence/src/infra/owner_read_model.rs`) consuming IAM
`iam.user.events` off `READMODEL_IAM_BROKERS=kafka-cmd:9001`. If that Kafka consumer dies,
the projections freeze while IAM keeps producing happily — so the producer side looks
perfect and everything downstream still *appears* to work, because the outbox keeps
replaying historical mints. Observed once: frozen 27h, six events unread.

```bash
# The diagnostic. "has no active members" + non-zero LAG == this failure.
docker exec gridtokenx-kafka-cmd /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server kafka-cmd:9001 --describe --group aggregator-owner-readmodel-iam-group
# Corroborate: newest projection row vs now
docker exec gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx_meter -tAc \
  "SELECT max(updated_at) FROM meter_owner_read_model"
# Symptom in the aggregator log, every ~60s:
#   librdkafka: REQTMOUT [thrd:GroupCoordinator]: GroupCoordinator: Timed out
```

Fix: `docker compose restart aggregator-bridge` — it rejoins the group and drains to lag 0.

> **Do not read `⚡ minted` lines as proof the pipeline works.** Check for
> `📤 Mint outbox: draining N pending surplus mint(s)` first — hundreds of mints can be the
> outbox replaying old work while every *fresh* resolve is failing. Count distinct meters in
> `no registered owner` against meters onboarded in the same window.

## Ingest 401 after an aggregator restart — cached key hid IAM drift

The aggregator caches api-key validations, so ingest can return `202` from cache while the
key is actually invalid at IAM. A restart clears the cache and every request then hits IAM:

```
🚫 API Key rejected by IAM: Invalid API Key
```

`just check-apikey` → `just seed-apikey` → re-check. Seen immediately after restarting the
aggregator to fix the consumer above; the restart did not cause the drift, it exposed it.

## Known gotchas (memory-linked)

- `[[mint-path-aggregator-signed]]` — surplus mint is aggregator-signed → chain.tx.mint; RBAC needs AggregatorBridge role.
- `[[aggregator-ingest-401-iam-key]]` — ingest 401 can be IAM rejecting a placeholder-hash api key, not just a missing header.
- `[[bridge-apikey-no-cache-iam-dos]]` — unattributed meters flood Postgres owner lookups (nil-UUID); onboard or negative-cache.
- `[[meter-service-read-only-ingest]]` — readings ingest ONLY via the bridge; meter-service has no submit endpoint.
- Settlement bins live **in-process → InfluxDB**, NOT in a `gridtokenx:settlement:*` Redis key.
