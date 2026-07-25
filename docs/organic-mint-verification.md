# Organic surplus mint — physics-driven, verified on-chain

Proof that a GRID surplus mint can originate from **real PV physics** (not the
synthetic `force_surplus.py` injection), end-to-end from solar irradiance to an
on-chain `MintGeneration` credited to a user's wallet.

## Physics stack (the surplus is real, not random)

- **Solar** (`gridtokenx-smartmeter-simulator/.../devices/solar.py`): `pvlib` PVWatts —
  solar position → Ineichen clear-sky → plane-of-array irradiance (tilt/azimuth) →
  cell-temp derate → `pvwatts_dc` → inverter model, clamped to nameplate.
- **Grid** (`core/grid_manager.py`): `pandapower` AC power flow on a GridLAB-D GLM feeder.
- Independent pvlib recompute for Bangkok (13.75, 100.5), 5 kW: noon POA 884 W/m² → **3.785 kW AC**;
  night/dawn → 0. Textbook, matches the sim.

## Reproduce: force the sim into solar daytime

The sim clock is wall-clock local time-of-day; `SMARTMETER_TIMEZONE` reinterprets it
so `pvlib` computes noon irradiance while reading **timestamps stay current-dated**
(bins stay current, settlement fires normally). With the sim clock near `02:xxZ`:

```bash
SMARTMETER_TIMEZONE=Etc/GMT+3 docker compose up -d --force-recreate --no-deps smartmeter-simulator
```

Confirm generation kicks in (a solar prosumer over-generates):

```bash
curl -s "http://localhost:12010/api/v1/meters?limit=2000" | \
  jq '[.meters[] | select(.has_solar and (.current_generation_kw//0) > (.current_consumption_kw//0))] | length'
```

Observed: 20/80 meters generating; e.g. gen 4.7–7.7 kW vs con 2–3.9 kW → real surplus.

## Attribute a claimed meter to a user (so the surplus settles)

The aggregator only mints for an owner-attributed meter. For a meter claimed via
meter-service, wire the bridge's Redis registry + owner read-model:

```bash
S=<solar-meter-serial>; USER=<iam-user-id>; W=<user-wallet>
PUB=<ed25519 pubkey = sha256("gridtokenx-sim:$S")>   # sim MeterKey derivation
docker exec gridtokenx-redis redis-cli SET "gridtokenx:devices:$S:pubkey" "$PUB"
docker exec gridtokenx-redis redis-cli SET "gridtokenx:meters:$S:user_id" "$USER"
docker exec gridtokenx-redis redis-cli SET "gridtokenx:meters:$S:wallet"  "$W"
docker exec gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx_meter -c \
  "INSERT INTO meter_owner_read_model (serial_number,user_id,wallet_address,updated_at)
   VALUES ('$S','$USER','$W',now())
   ON CONFLICT (serial_number) DO UPDATE SET user_id=EXCLUDED.user_id, wallet_address=EXCLUDED.wallet_address, updated_at=now()"
```

Surplus that accumulated **before** the wallet was wired is **not lost** — the
aggregator logs `surplus mint deferred: no wallet registered ... kept for retry`
and flushes it the moment the wallet is registered.

## Verified result (user `buyer_1`, meter `4c66e0a8`)

- meter live: gen **4.722 kW**, con 3.281 kW → **surplus 1.441 kW** (has_solar, pvlib noon)
- bridge: `✅ Telemetry signature verified`, owner resolved to buyer_1
- settlement bin swept → `⚡ minted 0.355468 kWh surplus for meter 4c66e0a8 (sig=5tyuU2S…, slot=76937)`
- **on-chain**: slot 76937, `err None`, `Instruction: MintGeneration`
- **wallet credited**: buyer_1 GRID `0.037972 → 0.393440` (**+0.355468**, matches the mint exactly)

## Why this proves "organic"

The minted amount is a **non-round fractional kWh** (`0.355468`, and per-window
`0.0056…`) — the exact accumulated PV surplus the physics produced over the
partial window — unlike the synthetic round `5.0` kWh from `force_surplus.py`.

## Idempotency note

After the confirmed mint, the aggregator's retry loop re-logs `⚡ minted …` with the
**same sig** — an idempotent replay. The on-chain `gen_mint` PDA (keyed by
`meter_id + window_start_ms`) **no-ops a replay**, so the balance moves exactly once.
On-chain clock drift was 0 at test time (validator restart resynced the clock), so the
current-window mint landed with no `--at` alignment.

Related: [token-lifecycle-track-results.md](token-lifecycle-track-results.md) (mint/settle/burn),
[`scripts/token_lifecycle_track.sh`](../scripts/token_lifecycle_track.sh).
