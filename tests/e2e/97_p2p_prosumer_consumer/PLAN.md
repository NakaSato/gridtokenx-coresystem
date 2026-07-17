# Suite 97 — P2P Energy Trade: Prosumer ↔ Consumer (plan)

> **Status: IMPLEMENTED** — as the standalone bash suite `run.sh` in this directory
> (not the pytest layout originally sketched below; see "Files" and "Open questions",
> both since resolved). Phase annotations below note where the implementation differs.

Scenario: 2 users (1 prosumer, 1 consumer) go through full lifecycle — register,
verify, add meter, trade — using **real self-service APIs only** (no Redis/DB
backdoors), distinct from suite `90_golden_path` which uses a Redis backdoor for
meter registration and is deliberately service-generic (seller/buyer, not
prosumer/consumer roles).

Confirmed with user: 2 users total (1 prosumer, 1 consumer), not 3.

## Grounding (existing code/tests referenced)

- `tests/e2e/90_golden_path/test_golden_path.py` — closest existing analog; reused
  fixtures/pattern (`Stages` class, `make_user`, `_send_reading`, `place_order`).
- `scripts/register_users_meters_api.sh:145` — real self-service meter registration:
  `POST /api/v1/meters` (meter-service, JWT) → `{meter: {id, serial_number}}`.
- `tests/e2e/lib/db.py`, `redis_util.py`, `crypto.py`, `dlogs.py` — shared E2E helpers.
- Memory `register-flow-async-detached-gaps`: IAM `/verify` returns 200 before
  wallet/chain registration land; on-chain PDA registration is detached
  (~14–30s) — must poll DB/API, not assume synchronous completion.
- Memory `verify-airdrop-feature`: IAM auto-airdrops SOL to custodial wallet on
  email verify (`IAM_VERIFY_AIRDROP_SOL`) — wallet confirmation is a system
  action at verify time, not a user-submitted address.
- Memory `dev-stack-disables-rate-limits`: register rate-limit (5/hr/IP) is
  reset via `conftest.py:_reset_register_rate_limit()` — reuse it, don't
  reinvent.

## Phases

### Phase 1 — Register (2 users)
- `POST /api/v1/auth/register` for `prosumer` and `consumer` (distinct
  usernames/emails, tagged `e2e_p2p_prosumer_*` / `e2e_p2p_consumer_*`).
- Assert `201`/`200`, capture `user_id`.

### Phase 2 — Verify email → confirm wallet address
- Pull `email_verification_token` from DB (`lib/db.py`, mirrors
  `test-registration-e2e.sh`).
- `GET /api/v1/auth/verify?token=...` → expect `200`, JWT in
  `auth.access_token`.
- Assert `wallet_address` present on the verify response **or** poll
  `SELECT wallet_address FROM users WHERE id=...` for up to ~30s (per the
  async-detached-gaps memory) before failing — do not assume synchronous.
- This is the "confirm wallet" step: assert non-empty wallet, not that the
  user supplied one.

### Phase 3 — On-chain onboarding
- `POST /api/v1/me/registration` per user with `user_type: "prosumer"` /
  `"consumer"` + location.
- Accept `200/202/409` (idempotent path, mirrors golden path).
- Poll for on-chain PDA existence (DB flag or Chain Bridge read) up to ~30s —
  known detached/async gap, don't assert immediately.
- *(Implemented: `run.sh` gates on `users.blockchain_registered = t` via
  `docker exec` psql, up to `REG_CONFIRM_WAIT` = 45s; `SKIP_ONCHAIN=1` skips.)*

### Phase 4 — Add meter to account (real API, not Redis backdoor)
- Prosumer: `POST /api/v1/meters` (meter-service, JWT) with
  `serial_number`/`meter_type: smart_meter`/location → capture real
  `meter.id` (UUID) + `serial_number`.
- Consumer: same call — needed so consumption/telemetry and ownership are
  attributable, even though only the prosumer emits generation readings in
  this scenario.
- Assert `meter.id` returned and linked to the registering user (per
  `meter-readings-writer-and-verified` memory: `meter_id` FK → user via
  `meter_registry`, `is_verified=true` at register).
- *(Implemented: `run.sh` first tries real simulator device ids as the serial —
  solar-capable for the prosumer — retrying down a candidate pool since a meter
  is one-owner, then falls back to an invented serial; for a real sim id it also
  re-points the bridge's Redis device registry (pubkey + owner + wallet) so
  signed telemetry attributes to this run's user.)*

### Phase 5 — Trade together (P2P match)
- Optional but realistic: prosumer sends 2–3 signed GENERATION readings via
  `POST {ORACLE}/v1/private-network/ingest` (Ed25519-signed, backdated into
  the settlement window) — proves the prosumer has real surplus before
  selling, mirrors golden path stage 4/5.
- Prosumer places `sell` limit order, consumer places crossing `buy` limit
  order at the same price/zone — `POST /api/v1/orders` via Trading REST
  (`trade_hdr` gateway headers).
- Poll consumer's (taker) order until `filled_amount_kwh >= amount` (up to
  ~25s), matching golden path's crossing-order-is-reliable-taker rationale.

### Phase 6 — Best-effort evidence (not hard-failed)
- Settlement/mint: `dlogs.wait_for_log` on aggregator-bridge container for
  `"completed billing bins"`, chain-bridge for `"Success"` — skip if
  containers/platform unreachable (matches golden path's tolerance model).
- Notification: `POST` to Noti gRPC-JSON `SendNotification` for the prosumer
  (trade_filled template) — best-effort, skip on Noti-down.

## Stage/skip model

Same tolerance model as golden path, implemented with warn-and-continue in
bash rather than the pytest `Stages` accumulator: hard prerequisites are IAM
and meter-service reachability; the single hard gate is the Phase 5 P2P match
fill. Telemetry, settlement, and mint evidence are best-effort (warn, not
fail).

## Files (as implemented)

```
tests/e2e/97_p2p_prosumer_consumer/
  run.sh                    # standalone bash suite (no pytest file)
```

## Open questions — resolved in the implementation

1. Phase 5 signed telemetry: **included** — the prosumer pushes signed
   GENERATION readings (AES-256-GCM dlms-enc + mTLS, run inside the sim
   container) as best-effort proof of surplus; `SKIP_SURPLUS=1` opts out.
2. Consumer meter: **registered** — both users add a meter via the real
   meter-service API.
3. Run mode: **standalone bash script** (`run.sh`), like
   `scripts/e2e_two_user_trade.sh` — not a pytest suite.
