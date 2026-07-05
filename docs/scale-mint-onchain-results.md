# Fleet-Scale E2E On-Chain Mint Test — Results

> Harness: `.claude/skills/telemetry-hops/scripts/scale_mint.py`
> Raw per-run reports: `.claude/skills/telemetry-hops/scripts/.scale-state/results.jsonl`
> Date: 2026-07-03 · Stack: full secure docker stack (`AGGREGATOR_REQUIRE_SECURE=true`,
> AES-256-GCM `dlms-enc` + mTLS ingest), native `solana-test-validator` (Agave 3.1.10).

## What the test exercises (full Path-A pipeline, per meter)

1. **Onboard** — IAM register → verify → login via APISIX gateway (`:4001`), link
   deterministic primary wallet, claim meter in meter-service (`POST /api/v1/meters`,
   durable `meters` row = owner source of truth).
2. **Keys** — Ed25519 pubkey + AES-256-GCM enckey pipelined into the bridge Redis
   device registry; owner map seeded to warm the ingest hot-path cache.
3. **Ingest** — one signed, encrypted (`dlms-enc`) surplus reading per meter over
   mTLS into `POST /v1/private-network/ingest` (`X-API-KEY` validated against IAM),
   all binned into the same already-completed 15-min settlement window.
4. **Settle + mint** — settlement sweep (30 s interval, 120 s grace) evicts every
   bin → one `chain.tx.mint` per meter over NATS JetStream → Chain Bridge signs and
   submits to Solana, confirmation-gated (durable outbox).
5. **Count** — mints counted by parsing the aggregator's
   `⚡ minted … for meter <serial> (sig=…, slot=…)` log lines against the run's exact
   serial set (Prometheus `aggregator_mint_total` is polluted by the background
   simulator's continuous traffic, so log-parse is the source of truth).

Serials are deterministic (`uuid5("scalemeter:{i}")`), so tiers nest: the 10 000-meter
fleet contains the 1 000-meter fleet; each tier only onboards its delta.
Each run uses a fresh past settlement window (chain-bridge dedups on
`mint:<meter>:<window_ms>`).

## Results

| Tier | Onboard (new) | Ingest accepted | Mints on-chain | Overall TPS | Steady TPS (median 10 s) | Peak TPS | Outcome |
|---|---|---|---|---|---|---|---|
| 5 (smoke) | 5/5, 4.6/s | 5/5, 84/s | 5/5 in 54.6 s | 7.25 | 0.5 | 0.5 | ✅ |
| 1 000 | 995, 8.6/s (conc 32) | 1 000, 329/s | **1 000/1 000** in 49 s | 29.3 | n/a¹ | n/a¹ | ✅ |
| 10 000 | cached (see incidents) | 10 000, 355/s | **10 000/10 000** (9 921 in-run + 79 retro via outbox) | 18.4 | **37.7** | 123 | ✅ |
| 10 000 (clean re-run) | cached | — | **10 000/10 000**, no retro needed | 22.1 | 40.5 | 258.3 | ✅ |
| 25 000 (baseline) | 25 000 owned, 7.4/s (conc 16) | 25 000, ~125/s | **2 559/25 000** — congestion collapse | 16.7 → 3.7 (decaying) | n/a² | n/a² | ❌ collapse |
| 25 000 (**tuned**, see A/B below) | cached | 25 000, 66/s | **25 000/25 000** (24 764 in main burst + 236 retro after wallet re-link) | 23.2 (incl. straggler tail) | **14.6** | 193.4 | ✅ |
| 50 000 | _skipped on baseline — same failure mode as 25 k, no new information_ | | | | n/a³ | n/a³ | — |
| 100 000 | **[TODO: fill on completion]** | **[TODO]** | **[TODO]** | **[TODO]** | **[TODO]** | **[TODO]** | ⏳ in progress |

¹ The 1 000-tier run predates the harness's per-mint-timestamp TPS breakdown (`results.jsonl` line 1 has no `tps` object, only aggregate `mints_per_sec`) — steady/peak genuinely weren't computed for it, not omitted. A later 1 000-tier re-run (warm caches, 6.4 s total span) measured overall 156.9, steady 100.0, peak 100.0 — not comparable to the cold-cache 49 s run above, so not merged into this row.
² Collapsed before reaching a steady state (goodput decayed 16.7 → 3.7 mints/s and never stabilized); a windowed median/peak isn't a meaningful figure for a run that never converges.
³ Tier skipped entirely — no run, no data.

**Correction (was "~50 through p95"):** the 25 k-tuned row's steady TPS is the harness's own computed `steady_tps_median_10s` field for that exact run (`results.jsonl` line 9) — **14.6**, not ~50. The qualitative "~50 mints/s sustained" in the prose below described goodput loosely; the precise windowed-median figure is lower because the 10 s window spans the initial ramp-up as well as the steady burst.

Tier-10k TPS detail (from per-mint log timestamps + slots): active mint span 540.5 s,
completion spread p50 366 s / p95 536 s, slot-span cross-check 23.1 TPS
(1 075 slots × ~0.4 s), 12 621 dedup replays (≈2.3× publish amplification),
0 stale-rejects, 0 lost.

## The mint-number limit: burst ceiling between 10 k and 25 k per window

**Sustained mint throughput is ~20–38 TPS** (bounded by the Chain Bridge mint
consumer: `for_each_concurrent(8)` in
`gridtokenx-chain-bridge/crates/chain-bridge-api/src/nats_consumer/consumer.rs:129`,
each slot held for the full confirmation poll — commitment `confirmed`,
`api/service.rs:252-288`).

**A 10 000-mint burst in one window clears** in ~9 min: the aggregator outbox
re-signs a fresh envelope every 30 s retry tick
(`gridtokenx-aggregator-bridge/src/main.rs:596-633`), so the 55 s staleness gate
(`consumer.rs:708`) never trips; cost is 2.3× message amplification from reply
timeouts (`mint reply timeout 30 s`, `aggregator-persistence/src/infra/mint.rs:245`).

**A 25 000-mint burst collapses.** Observed live:

- Outbox reached 22 528 entries; the unbounded 30 s drain re-published *all* of them
  each tick → JetStream ingress ≫ consumer drain.
- Queue wait exceeded the 55 s staleness cap even for freshly-signed envelopes
  (measured envelope age at rejection: **127 s**) → **65 117 stale-rejects in
  3 min** (231 k total), consumer slots consumed by rejections.
- Goodput decayed 16.7 → 3.7 mints/s; backlog stopped shrinking = positive-feedback
  congestion collapse. Run stopped manually; dead outbox entries purged.

Failure boundary math: collapse begins when `outbox_backlog / consumer_goodput >
staleness_cap` (≈25 mints/s × 55 s ≈ 1.4 k in-queue tolerance, survivable while the
30 s re-sign keeps envelopes fresh faster than queue growth — empirically holds at
10 k, breaks by 25 k).

Per-window absorbable load at steady state ≈ 20–38 TPS × 900 s = **18 k–34 k
mints/window** — but only if arrival is spread; a single-sweep burst above ~10–15 k
hits the stale wall first.

## A/B: tuned stack clears the 25 k burst (2026-07-03)

Re-run of tier 25 k with three knobs changed (levers 1–2 from the ranking below,
now env-tunable rather than hardcoded):

| Knob | Baseline | Tuned |
|---|---|---|
| Chain-bridge mint consumer concurrency (`CHAIN_BRIDGE_MINT_CONCURRENCY`) | 8 (hardcoded) | **64** |
| Chain-bridge preflight (`CHAIN_BRIDGE_SKIP_PREFLIGHT`) | on | **skipped** |
| Aggregator mint reply timeout (`AGGREGATOR_MINT_REPLY_TIMEOUT_SECS`) | 30 s (hardcoded) | **120 s** |

Result (same fleet, fresh window `2026-07-03T12:45Z`, raw report in `results.jsonl`):

| Metric | Baseline 25 k | Tuned 25 k |
|---|---|---|
| Minted | 2 559/25 000, stopped manually | **25 000/25 000** |
| Goodput | 16.7 → 3.7 mints/s, decaying | overall 23.2, steady (median 10 s) 14.6 mints/s, no decay (p50 spread 255 s, p95 421 s from first mint) |
| Peak TPS (10 s) | — | 193.4 |
| Stale-rejects | 65 117 in 3 min (231 k total) | **0** |
| Dedup replays (publish amplification) | 22 528-entry outbox re-published every 30 s tick | **0** (10 k baseline had 12 621) |
| Slot-span cross-check | — | 59.5 TPS over 1 051 slots |

Why it works: 64 consumer slots drain the queue faster than the sweep fills it, so
envelope queue-wait never approaches the 55 s staleness cap — the positive-feedback
loop (stale-reject → outbox re-publish → deeper queue) never ignites. The 120 s
reply budget keeps the aggregator from re-publishing envelopes the bridge is still
confirming, which is what zeroed the dedup-replay amplification. Skipping preflight
removes one RPC round-trip per mint ahead of the confirm poll.

The straggler tail (236 meters, overall span inflated to 1 080 s / 23.2 TPS): same
class as incident 4 below — wallet-link casualties of the OOM-era onboards, cached
as owned but with no primary wallet. Mints deferred (`no wallet registered … kept
for retry`); an idempotent re-onboard of the 236 relinked wallets mid-run and the
durable outbox retro-minted **all of them into the original window** — second live
proof of the no-loss property. Main-burst goodput (24 764 mints) is the number that
reflects the tuned pipeline.

Remaining untried levers: mint batching (lever 3), batched confirmation polling
(lever 4) — next ~4–10× if needed.

## A/B 2: bounded client fan-out + 5 s cadence (2026-07-03, tier 10 k)

Second tuning pass attacking lever 2 structurally instead of via the longer reply
timeout: bound the *number of in-flight mint request-replies at the aggregator*
so bridge queue-wait can never approach the 55 s staleness cap, then shorten the
sweep/retry cadence so the permits stay busy.

| Knob | Value | Where |
|---|---|---|
| `MINT_INFLIGHT_LIMIT` | 128 (semaphore shared by settlement sink + outbox drain) | aggregator-bridge `ca2fc43`, `src/main.rs` |
| `BILLING_FLUSH_INTERVAL_SECS` | 30 → **5** | compose `ad0c42c` |
| `MINT_RETRY_INTERVAL_SECS` | 30 → **5** | compose `ad0c42c` |

Tier-10 000 progression on this axis (all with phase-1 bridge knobs; raw reports
in `results.jsonl`, runs of 2026-07-03T13:57 / 15:47 / 15:53 UTC):

| Stage | Overall TPS | Steady TPS (median 10 s) | Peak | Stale-rejects | Profile |
|---|---|---|---|---|---|
| bridge knobs only | 22.1 | 40.5 | 258 | in-run 0, but 30 s-wave bursts + reply-timeout churn | sawtooth |
| + `MINT_INFLIGHT_LIMIT=128` | 47.6 | 37.2 | 168 | 0 | waves, ~70 % idle between 30 s ticks |
| + 5 s cadence | **62.8** | **66.9** | 82.5 | 0 | flat (peak ≈ steady) |
| same knobs, tier **25 k** validation | 34.3 | 33.3 | 80.2 | **0** | flat, **ingest-gated** (arrival 36.2 readings/s) |

The bounded fan-out makes publish time ≈ processing time (envelopes are
timestamped at publish, so client-side flow control is what actually protects the
staleness gate at any backlog size — the 120 s reply timeout treats the symptom,
the semaphore removes the cause). The 5 s cadence then converts the wave/idle
pattern into a flat ~67 mints/s. 10 k mints complete in 159 s span; a 15-min
window absorbs ≈ 60 k meters at this rate.

**25 k validation run** (2026-07-03T16:44 UTC, `results.jsonl` line 14): ingest and
mint overlapped, and encrypted ingest itself sustained only 36.2 readings/s over
691 s — so mint steady TPS (33.3) sat right at the arrival rate. The pipeline kept
pace with ingest end-to-end: zero stale-rejects, zero duplicates, no backlog
build-up, flat profile (peak 80.2 shows headroom consistent with the 10 k
62.8/66.9 capacity result — the steady figure here is arrival-bound, not a
ceiling). Versus the first tuned 25 k burst above (23.2 overall / 14.6 steady /
193 peak, post-collapse recovery shape): 1.5× overall, 2.3× steady, and no spike
artifact. 24 995/25 000 minted within the 740 s watch (p50 spread 448 s, p95
702 s from first mint); the remaining 5 are wallet-less deferrals held in the
durable outbox (`no wallet registered … kept for retry` still cycling post-run),
i.e. the same retro-mint path proven in incident 4 — not losses. Retry churn
remains the visible inefficiency (prom `failed/mint_err` delta ≈ 25 k over the
run, i.e. ~1 failed attempt per mint before success) — lever 3/4 territory.

## Duplicate-publish guard for 100 k-scale bursts (2026-07-04)

`MINT_INFLIGHT_LIMIT` (A/B 2 above) bounds *how many* mint attempts run at once
but not whether the settlement sweep and the outbox's 30 s (now 5 s) drain tick
publish the *same* `(serial, window)` entry twice while its reply is still
pending — observed at the 10 k tier as ~9 900 bridge-side `"Submit already in
flight for this idempotency_key"` rejections, each one a wasted NATS
publish + Chain Bridge round-trip that would multiply at 100 k scale into
real queue pressure.

Added `MintInFlight` (`gridtokenx-aggregator-bridge/crates/aggregator-logic/src/mint_settlement.rs`):
a process-wide `HashSet<String>` of in-flight idempotency keys behind a
`Mutex`, claimed via an RAII guard (`try_begin`/`MintInFlightGuard`, releases
on drop — success, failure, or panic alike) shared across all four call sites
(`attempt_mint`'s sweep spawn, double-enqueue-failure fallback, best-effort
path, and drain loop). A key already claimed skips locally
(`skipped/in_flight` metric) instead of publishing — the drain retries next
tick. 15/15 `aggregator-logic` unit tests pass (2 new: claim-once-until-drop,
release-on-panic). Verified live at the 1 k tier: `dedup_replayed` went from
2 823 (measured before the purge above, itself inflated by the stale-backlog
grind) to **0** once `MintInFlight` was live and the stream was clean.

## 100 k tier (2026-07-04, in progress)

First run at 100 000 meters, with the fixes above live: `MintInFlight` guard,
`CHAIN_TX` stream `max-age=15m`, `CHAIN_BRIDGE_MINT_CONCURRENCY=128`,
onboard-concurrency clamped to 16 (memory-fix incident 8 above). 50 595 new
onboards (49 405 cached from prior tiers) at ~6–8/s.

**TODO on completion, fill in:**
- Onboard: new/cached split, final rate, any 409/restart incidents beyond
  the benign wallet-link-conflict class already documented.
- Ingest: accepted/sent, rate.
- Mint: minted/expected, **verified via the on-chain PDA probe method**
  (incident 7 above), not log-parse or Prometheus alone — those are proven
  insufficient at scale.
- TPS: overall, steady (median 10 s), peak, slot-span cross-check.
- Churn: stale-rejects, dedup replays (should be ~0 given the `MintInFlight`
  fix + bounded stream retention), duplicate-detected.
- Sample sig `solana confirm` → `Finalized`.
- Whether the collapse boundary (previously observed between 10 k and 25 k
  on the untuned stack) reappears at 4× the tuned-25 k proof point, or
  whether the lever-2 structural fix (bounded fan-out + 5 s cadence) pushes
  it further out.

## On-chain evidence

Sample mint tx verified `Finalized` (`solana confirm`), e.g.
`4RJuEzSmyB6Ctxq4S3zVCQWp9khTbEg2tA693yfapBLxohUa2fK2S5E8qYpJFpF5wJ6LVjL28ak9K4KFA96mTnwB`.

> **Ledger-pruning caveat:** the validator runs `--limit-ledger-size 10000`, so
> `solana confirm` only resolves *recent* signatures — older mint sigs (still listed
> with slot in `results.jsonl` / aggregator logs) return "Not found" after pruning.
> Chain-bridge gates every success reply on `confirmed` commitment at mint time;
> token-account state survives pruning.

Tier-10k sample sigs (in `results.jsonl`, pruned from ledger by the time of writing):
meters `d0760a8e-…`, `c6342534-…`, `ad5f5927-…` — kwh 0.25 each, window
2026-07-03T08:45Z.

## Operational incidents hit at scale (all root-caused)

1. **IAM OOM crash-loop** — 768 M compose limit vs `Argon2::default()` (19 MiB per
   in-flight hash, `iam-logic/src/password.rs:16`) × onboard concurrency + background
   load; 86→113 restarts before fix. Limit now **2 G** (1536 M still OOMed once);
   harness clamps onboard concurrency to 16 and saves the owner cache every 500.
2. **Fee-payer drain** — 10 k new ATAs ≈ 20+ SOL rent; payer hit 0.0018 SOL →
   `InsufficientFundsForRent` on every mint until a 500 SOL airdrop. Budget ≈
   **0.00204 SOL per new-meter mint** (ATA rent) + fees.
3. **IAM register rate-cap** — `IAM_REGISTER_LIMIT=10000,3600` 429-blocked a 15 k
   bulk onboard at ~14 k; raised to `100000,3600` in `.env` for benchmarks.
4. **79 wallet-less meters** — wallet-link casualties of the OOM era, cached as
   onboarded; mints deferred (`no wallet registered … kept for retry`) until
   re-onboard fixed the links, then the **durable outbox retro-minted all 79 into the
   original window** — no-loss property proven live.
5. **Docker log rotation** — the stale-reject storm rotated early `⚡ minted` lines
   out of `docker logs`; long-horizon recounts must use `results.jsonl`, not logs.
6. **`/verify` rate-limit knob missing from the running image (2026-07-04)** — a
   100 k-tier onboard hit a 429 wall at ~294 new onboards. Root cause: the running
   `iam-service` image predated commit `6b2e7ab` (`fix(iam): give /verify its own
   rate-limit env override`), so `/verify` still shared the old hardcoded 100/60 s
   budget instead of `IAM_VERIFY_LIMIT=10000,60` — exactly the failure mode that
   commit was written to fix. Rebuilding the image resolved it; **lesson: after any
   `.env`/image-relevant fix, confirm the *running* container's image build time is
   newer than the fixing commit before trusting a fleet-scale run**, don't just
   check `.env`/compose.
7. **995/1 000 mints silently lost during a stale-backlog grind (2026-07-04)** — a
   1 k-tier smoke run's outbox emptied (`HLEN mint_outbox` → 0) without a matching
   `⚡ minted` count; Prometheus/log counters looked clean but were not ground
   truth. Root-caused via **direct on-chain PDA probe** (deriving each meter's
   `gen_mint` seed — `[b"gen_mint", meter_id, window_start_ms]` on the energy-token
   program — and checking existence with `getMultipleAccountsInfo`), which showed
   only 5/1 000 PDAs existed for the window vs 1 000/1 000 on a prior proven window.
   Enabling condition: the chain-bridge `CHAIN_TX` JetStream stream had **no
   `max-age` retention** (`nats stream info` showed 1.08 M messages / 1.5 GiB
   accumulated across every prior run) — a stale multi-hour backlog meant every
   fresh mint request queued behind ~41 s-old (and older) stale-rejected envelopes,
   and something (mechanism not fully isolated — candidate: reply-subject
   crosstalk between the grind-era backlog and live requests) caused entries to
   drop from the outbox without a confirmed on-chain mint. **Detection**: the PDA
   probe is now the trusted ground truth for "did this window actually mint" —
   outbox-empty and log/Prometheus counts are NOT sufficient proof at scale.
   **Heal**: re-running the same window (idempotent, `mint:<meter>:<window_ms>`
   dedup) retro-minted all 1 000 cleanly once the stream was purged. **Fix**: set
   `CHAIN_TX` retention to `max-age=15m` (`nats stream edit CHAIN_TX --max-age=15m`)
   so a backlog can no longer accumulate past a bounded age.
8. **OrbStack VM memory exhaustion mid-onboard (2026-07-04)** — not an IAM bug: the
   8 GiB OrbStack VM hit 125 MB available / 4.5 GB swapped, with kernel
   `VM_FAULT_OOM` messages in `dmesg`, causing IAM's clean-exit-then-restart policy
   to trigger repeatedly under its ~1.7 GiB Argon2 working set (which is itself
   legitimate, not a leak). This was also the likely cause of an earlier BuildKit
   image-build wedge. **Fix**: stopped ~1.5 GB of benchmark-irrelevant containers
   (3 Kafka brokers, Grafana, Prometheus, the aggregator's dedicated InfluxDB, 2
   UIs, explorer, noti-service, 3 exporters, both OpenLEADR containers) — all
   degrade-safe paths by this system's design, so stopping them doesn't affect the
   mint pipeline. VM available memory recovered 125 MB → ~4 GB; restart these
   containers after the benchmark run completes.

## Bottleneck ranking & tuning levers (levers 1–2 applied in the tuned A/B run above)

1. **Chain-bridge mint consumer concurrency 8** (`consumer.rs:129`) — the TPS
   ceiling; each slot blocks on confirmation. One-line raise to 32 ≈ 4× TPS.
2. **Outbox retry churn** — 30 s reply timeout (`mint.rs:245`) + fixed 30 s
   republish tick with unbounded drain (`main.rs:596-633`). Longer timeout /
   exponential backoff / bounded drain removes the collapse feedback loop.
3. **1 mint = 1 tx, no batching, no priority fee** (`api/service.rs:196-217`) —
   batching ~10 `mint_to`+ATA per tx divides txs, confirm polls, and Vault Transit
   sign round-trips by 10.
4. **Confirmation polling** — ≤24 × 250 ms `getSignatureStatuses` per mint
   (`service.rs:252-288`); batch one call across all in-flight sigs.
5. **Onboard 7–9/s** — Argon2 memory cost × IAM container limit; dev-profile hash
   params or an in-service memory-bounded semaphore would ~4× it.
6. **Ingest 125–355/s** — never the limit in any tier.

## Reproduce

```bash
cd gridtokenx-smartmeter-simulator/backend
AGGREGATOR_BRIDGE_URL=https://localhost:4030 \
AGGREGATOR_API_KEY=engineering-department-api-key-2025 \
REDIS_URL=redis://localhost:7010 PYTHONUNBUFFERED=1 \
  uv run python ../../.claude/skills/telemetry-hops/scripts/scale_mint.py \
  --meters 10000 --onboard-concurrency 16   # add --onboard-only to pre-warm a fleet
```

Fund the payer first (`solana airdrop 100 EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ`,
repeat as needed): each new meter's first mint costs ~0.00204 SOL in ATA rent.
