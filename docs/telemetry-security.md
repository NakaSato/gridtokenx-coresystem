# Smart-Meter Telemetry Security

> Last reviewed: 2026-06-26

The simulator → Aggregator Bridge DLMS/COSEM telemetry path is hardened in six
layered, independently-toggleable phases. Each is **off by default** so dev/e2e
keep their conveniences; flip them all on together with `just secure-up`.

## Hardening layers

| Phase | Protection | Flag | Side |
| ----- | ---------- | ---- | ---- |
| 1 | **TLS** — telemetry encrypted in transit | `IOT_GATEWAY_TLS_CERT` / `_KEY` (on by compose default) | bridge serves HTTPS, sim verifies via `AGGREGATOR_TLS_CA` |
| 2 | **Payload encryption** — per-meter AES-256-GCM + monotonic replay counter | `SMARTMETER_ENCRYPT_ENABLED` | sim seals OBIS into a `dlms-enc` envelope; bridge decrypts |
| 3 | **Key rotation** — random per-meter GUEK wrapped by a Vault Transit KEK; only the wrapped blob is at rest in Redis | `SMARTMETER_KEY_ROTATION_ENABLED` (+ `VAULT_*`, `VAULT_METER_KEK_NAME`) | sim wraps + versions (`kid`); bridge unwraps via Vault |
| 4 | **Ingest lockdown** — reject every bypass (unsigned `simulator`, unverified-telemetry escape hatch, plaintext downgrade) | `AGGREGATOR_REQUIRE_SECURE` | bridge |
| 5 | **Rotation lifecycle** — version pruning past the grace window + background auto-rotation | `AGGREGATOR_KEY_GRACE_VERSIONS`, `SMARTMETER_KEY_ROTATION_INTERVAL_S` | sim |
| 6 | **mTLS** — bridge authenticates the sim at the transport layer (client cert) | `IOT_GATEWAY_TLS_CLIENT_CA` (+ `AGGREGATOR_TLS_CLIENT_CERT` / `_KEY`) | bridge verifies, sim presents `smartmeter-simulator` client cert |
| 7 | **At-rest stream encryption** — the full register set is AES-256-GCM sealed in the zone/unified Redis streams (opaque at rest) | `AGGREGATOR_ENCRYPT_STREAMS` (needs Vault) | bridge encrypts on disseminate, the in-process zone ingester decrypts |

Together: confidentiality + integrity + authenticity + anti-replay + mutual
auth + rotating keys (raw key never persisted) + enforced no-downgrade. Aligned
with the DLMS/COSEM security-suite model. This is the meter-telemetry
counterpart to the formerly-removed edge mTLS (see [SECURITY.md](../SECURITY.md)).

## Enable everything (secure profile)

```bash
just gen-certs        # dev CA + server/client certs (once)
just orb-up           # stack up
just secure-up        # provisions the Vault KEK, then re-ups with secure.env layered over .env
```

`just secure-up` layers `secure.env` over `.env` — that file holds the one-switch
secure preset (it documents the same matrix). Plain dev is `just dev-up`
(`.env` only, all flags off).

## Verify

```bash
just sim-ingest       # outbound DLMS status: expect "HTTP/1.1 202 Accepted"
just key-status       # per-meter current key version (kid)
just rotate-keys      # rotate the fleet (or `just rotate-keys <meter_id>`)
```

In secure mode a frame that is not an authenticated, encrypted `dlms-enc` over
mTLS is rejected before reaching settlement: no-client-cert fails the TLS
handshake, plaintext / `simulator` / downgrade returns `426`, a bad signature or
replayed counter returns `403` / `409`.

## At rest in the streams

`AGGREGATOR_ENCRYPT_STREAMS` seals the disseminated `DeviceReading` with a
fleet-wide AES-256 **SEK** before it is XADDed to the zone and unified Redis
streams, so the full register set is opaque at rest — a raw Redis dump yields
`{event_type, enc:{nonce, ciphertext}}`, no voltage/energy/OBIS. The SEK itself
is Vault-KEK-wrapped at `gridtokenx:stream:sek` (raw key never at rest) and
stable across restarts so existing entries stay decryptable. The in-process zone
ingester decrypts transparently; `trading-service` already ignored these entries
(its `Event` type never matched the meter envelope). **InfluxDB and Kafka are
intentionally not encrypted** — they carry only an energy/operational subset and
exist to be queried (dashboards, consumers); the full privacy-sensitive profile
lived only in the streams, which this closes. True at-rest for the query-able
sinks belongs at the storage layer (Redis/Influx auth + disk encryption).

## Keys at rest

With rotation on, Redis holds only Vault-wrapped GUEKs
(`gridtokenx:devices:{id}:enckey:v{kid}` = `vault:v1:…`); the raw AES key never
touches disk. The Vault Transit KEK (`gridtokenx-meter-kek`) is provisioned by
`just provision-kek` and self-healed by the bridge on startup (the dev Vault is
in-memory). Key versions are wall-clock-monotonic so a restart never re-issues
an old `kid` with a new key.
