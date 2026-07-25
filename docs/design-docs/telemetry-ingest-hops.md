# Telemetry Ingest Hops — Smart Meter → DLMS/COSEM + Encryption → Aggregator Bridge

Wire-level, hop-by-hop trace of the **ingest leg**: how a smart-meter reading is
encoded (IEC 62056 DLMS/COSEM), signed, encrypted, transported, and admitted into
the Aggregator Bridge. Every claim cites `path:line` in the real code.

> Companion to the paper's DLMS-frame byte layout
> (`Paper/sections/settlement-model-invariants-en.typ` — `@tbl:dlms-frame`) and the
> mint leg in [telemetry-hops skill](../../.claude/skills/telemetry-hops/SKILL.md).
> The mint half (settlement → `chain.tx.mint` → on-chain) is documented separately.

## TL;DR

Two **nested cryptographic envelopes** + one transport layer, applied in a fixed
order and unwound in reverse:

- **Inner — Ed25519 signature** (authenticity / non-repudiation). Made *before*
  encryption, rides *inside* the plaintext. Covers `device_id:kwh:timestamp_ms`.
- **Outer — AES-256-GCM `dlms-enc`** (confidentiality + integrity + **replay**).
  Monotonic counter bound into the GCM AAD.
- **Transport — TLS** + HTTP `X-API-KEY`.

Sim does **sign-then-encrypt**; bridge does **decrypt-then-verify**. Each layer is
an independent gate that can drop the reading (fail-closed).

## The hop chain

```
SMART METER (sim)   gridtokenx-smartmeter-simulator/backend/src/smart_meter_simulator/transport/aggregator_bridge.py
  │ reading {generated_kwh, consumed_kwh, V, I, f, PF, …}
  ▼
[A] OBIS/COSEM encode → JSON keyed by IEC 62056 OBIS codes
  │   1.1.1.8.0.255=import Wh, 1.1.2.8.0.255=export Wh, +TOU/demand/DR/V/I/f
  │   (OBIS consts aggregator_bridge.py:62-92; _build_obis_payload:195)
  ▼
[B] Ed25519 SIGN (inner, authenticity)
  │   canonical = "{meter_id}:{kwh}:{timestamp_ms}"  (aggregator_bridge.py:225)
  │   sign_base58 (:169,:226); key = Ed25519(sha256("gridtokenx-sim:{meter_id}")) (:149)
  │   signature rides INSIDE the plaintext payload
  ▼
[C] AES-256-GCM SEAL (outer, dlms-enc)   _encrypt_envelope (aggregator_bridge.py:307)
  │   plaintext = OBIS JSON (incl. sig); key = per-device GUEK enckey (32 B)
  │   nonce = 96-bit random (:330); AAD = "{device_id}:{counter}" (:331) ← replay guard
  │   AESGCM(key).encrypt (:332); envelope = {counter, nonce(b64), ciphertext(b64)} (:334)
  ▼
[D] HTTPS POST   protocol="dlms-enc" (:469); ingest_url (:358); POST (:484)
  │   POST https://<host>:4030/v1/private-network/ingest    TLS ALWAYS (docker-compose.yml:809)
  │   header  X-API-KEY: <key>   (aggregator_bridge.py:366)
  ▼
════════════════════ TRUST BOUNDARY ════════════════════
  ▼               AGGREGATOR BRIDGE  gridtokenx-aggregator-bridge/crates/aggregator-api/src/
[1] api_key_auth middleware   X-API-KEY → IAM VerifyApiKey (+pos/neg cache)   401 else   (auth.rs)
  ▼
[2] DECRYPT dlms-enc FIRST   ingest_private_network (handlers.rs:335) → decrypt_dlms_envelope (:236)
  │   enckey from Redis gridtokenx:devices:{id}:enckey; GCM verify+decrypt, AAD binds device_id:counter (:306)
  │   then stateful :ic replay CAS — check_and_bump_counter rejects counter <= stored (:319-325, crypto.rs)
  │   fail → "decrypt failed" / DecryptOutcome::Replay
  ▼
[3] secure_mode_gate (handlers.rs:87,375)   not-encrypted → 426 UPGRADE_REQUIRED (no plaintext downgrade)
  ▼
[4] canonical rebuild + Ed25519 VERIFY   canonical_sign_value (:451) → verify_rest_signature (:462)
  │   pubkey from Redis gridtokenx:devices:{id}:pubkey; FAIL-CLOSED 403 invalid / 401 verify-err (crypto.rs)
  │   → "✅ Telemetry signature verified (REST)"
  ▼
[5] DLMS/COSEM DECODE   dlms_stack.map_payload (handlers.rs:535; stacks/dlms.rs)
  │   OBIS codes → DeviceReading {generated/consumed_kwh + metadata registers}
  ▼
[6] OWNER RESOLVE   MeterRegistry 3-tier: local cache → Redis → Postgres (infra/meter_registry.rs)
  │   serial → (user_id, wallet); nil → unattributed (no settlement)
  ▼
[7] DISSEMINATE fan-out   disseminate_reading → router.disseminate (handlers.rs:531,541)
      ├─ zone Redis stream  gridtokenx:events:zone_N   (operational path, full register set)
      ├─ InfluxDB v2        (realtime history, async fire-and-forget)
      ├─ Kafka              MeterReadingEvent (V/f/PF/sig cherry-picked)
      ├─ Postgres           meter_readings sink (AGGREGATOR_PG_READINGS)
      └─ settlement bin     15-min billing window → surplus → mint leg
```

## Trust gates (each drops the reading independently)

| Hop | Protects against | Mechanism | path:line |
|---|---|---|---|
| D transport | eavesdrop / MITM | TLS (ingest port always TLS) | `docker-compose.yml:809` |
| 1 api-key | unauthorized sender | `X-API-KEY` → IAM + cache | `crates/aggregator-api/src/auth.rs` |
| 2 decrypt | confidentiality | AES-256-GCM, AAD binds `device_id:counter` into the tag | `handlers.rs:306` |
| 2b replay | frame replay | stateful `:ic` monotonic CAS (`check_and_bump_counter`), rejects counter ≤ stored | `handlers.rs:319`; `crypto.rs::check_and_bump_counter` |
| 3 secure gate | plaintext downgrade | `426` unless `dlms-enc` | `handlers.rs:87,375` |
| 4 sig verify | **authenticity** (device identity) | Ed25519 vs Redis pubkey, fail-closed | `handlers.rs:462`; `crypto.rs` |
| 6 owner resolve | attribution | serial → user, 3-tier registry | `infra/meter_registry.rs` |

## Key facts

- **Order matters.** Sim: sign → encrypt → TLS. Bridge: api-key → decrypt →
  secure-gate → verify-sig → decode → resolve → disseminate. The signature is made
  before encryption and verified after decryption, so it authenticates the reading
  regardless of transport.
- **Two keys per device in Redis.** `gridtokenx:devices:{id}:pubkey` (Ed25519, sig
  verify) and `gridtokenx:devices:{id}:enckey` (32-byte GUEK, AES). Both are
  **positive+negative-TTL cached** to bound IAM/Redis floods, but the signature is
  **verified on every call** — only the static key *fetch* is cached, never the
  verdict (`crates/aggregator-persistence/src/infra/crypto.rs`).
- **Replay resistance — two mechanisms, the CAS is the operative one.** (i) the
  invocation counter is folded into the GCM AAD (`device_id:counter`,
  `handlers.rs:306`) so it cannot be altered without breaking the tag; (ii) after a
  frame authenticates, the bridge runs a stateful compare-and-set on Redis
  `gridtokenx:devices:{id}:ic` — `check_and_bump_counter` (`crypto.rs`) rejects any
  counter `<=` the stored value (`DecryptOutcome::Replay`, `handlers.rs:319-325`)
  and advances it **only** on an authenticated frame (`handlers.rs:318`). The CAS,
  not the AAD, is what refuses a replayed *identical* frame; `:ic` is deliberately
  **not** cached (authoritative per call), unlike `:pubkey`/`:enckey`. The binary v4
  gRPC path instead derives its nonce `Manuf(3)+TS(8)+Ver(1)=12` (not transmitted,
  `aggregator-stacks/src/binary_decoder.rs`) and leans on strictly-increasing
  timestamps rate-limited on-chain by the oracle's `min_reading_interval = 60` s
  (`gridtokenx-anchor/programs/oracle/src/instructions/initialize.rs`; enforced in
  `submit_meter_reading.rs`) for nonce uniqueness.
- **Canonical sign value is protocol, not presentation.** `{device_id}:{kwh}:{ts_ms}`
  must be byte-identical both sides; number formatting mirrors Rust `f64::to_string`
  (`aggregator_bridge.py:117`).
- **Two envelope encodings coexist.** JSON `dlms-enc` (REST, nonce transmitted) and
  binary v4 (gRPC, nonce derived) — same AES-256-GCM, same per-device key.

## Observed failure modes (live, this stack)

- Missing `:pubkey` → `🚫 REST signature rejected … Public key not found in Redis`
  (drop at gate [4]). Fix: seed the deterministic pubkey.
- Plaintext `http://` / unencrypted frame to a secure stack → `426 Upgrade Required`
  (gate [3]); a plain-HTTP hit on the always-TLS port garbles rather than 4xx-ing.
- Downstream consumer wedge (owner read-model / mint) is **not** an ingest failure —
  ingest still 202s; the reading lands in the zone stream + `meter_readings`.
