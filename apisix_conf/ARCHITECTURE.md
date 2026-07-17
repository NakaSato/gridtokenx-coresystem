# apisix_conf — Architecture

> Apache APISIX configuration for the **user-facing gateway** — the single public HTTP entry point
> for web clients (trading portal, explorer). Runs as a container defined in the root
> `docker-compose.yml`; this folder holds only its mounted config. This doc covers **only** the
> contents of this folder + how the gateway is wired.

---

## 1. What This Is

APISIX is the **public internet gateway** for the Exchange platform. All browser/app traffic enters
here, gets authenticated, has identity headers injected, and is fan-routed to the backend services
(IAM, Trading, Meter, Noti, Smartmeter Simulator, plus a Solana JSON-RPC proxy). IoT/edge telemetry
does not pass through APISIX — it ingresses directly to the Aggregator Bridge IoT gateway
(Ed25519-signed payloads).

Runtime: `apache/apisix:3.15.0-debian`, **standalone mode** (`APISIX_STAND_ALONE=true`) — APISIX
reads routes from a static YAML file instead of etcd. No control plane, no admin API in practice;
edit the YAML and restart.

## 2. Files

| Path | Role |
| :--- | :--- |
| `config.yaml` | APISIX runtime config — `data_plane` role, `config_provider: yaml`, `node_listen: 9080`, websocket enabled, SSL listener on `9443` |
| `apisix.yaml` | The declarative data plane: `plugin_configs`, `routes`, `ssls`, `consumers` |
| `certs/` | Raw dev TLS cert/key files (gitignored); their PEMs are inlined into the `ssls` block of `apisix.yaml` |

Both YAML files are bind-mounted read-only into the container:

```
./apisix_conf/apisix.yaml → /usr/local/apisix/conf/apisix.yaml
./apisix_conf/config.yaml → /usr/local/apisix/conf/config.yaml
```

## 3. Ports (from `docker-compose.yml`)

| Host | Container | Purpose |
| :--- | :--- | :--- |
| `4001` | `9080` | **User proxy HTTP** (the public entry point) |
| `8443` | `9443` | User proxy HTTPS (self-signed dev cert — see `ssls` in `apisix.yaml`) |
| `8001` | `9180` | Admin HTTP (unused in standalone) |

Internally other services reach it as `http://apisix:9080`.

## 4. Auth & Identity Injection

Central shared `plugin_config` **id 1** ("Shared JWT auth + user-id extraction + CORS") is attached
to every authenticated route via `plugin_config_id: 1`:

1. **`jwt-auth`** (`key_claim_name: iss`, `store_in_ctx: true`) — validates the bearer JWT against
   the `consumers` table.
2. **`serverless-post-function`** (access phase) — pulls `sub` from the JWT payload and injects
   downstream identity headers:
   - `x-gridtokenx-user-id: <sub>`
   - `x-gridtokenx-role: api-gateway`
   - `x-gridtokenx-gateway-secret: $GRIDTOKENX_GATEWAY_SECRET` (env, dev fallback hardcoded)
3. **`cors`** — permissive CORS, with `expose_headers: X-Total-Count,X-Has-More` so the browser
   can read the meter-service pagination headers cross-origin.

The single configured consumer:

```yaml
consumers:
  - username: gridtokenx_user
    plugins:
      jwt-auth:
        key: "gridtokenx-iam-service"
        secret: "dev-jwt-secret-key-...-2025"   # DEV secret — see §7
```

Public/unauthenticated routes (login, register, verify, password reset, system config, public grid/
meter reads, health) use `proxy-rewrite` to set the gateway headers directly **without** JWT.

## 5. Routing

Routes are grouped by backend:

| ID(s) | Service | Path prefix(es) | Upstream node(s) |
| :--- | :--- | :--- | :--- |
| 10 | IAM public REST | `/api/v1/auth/{login,register,verify,forgot,reset,logout,refresh,resend-verification,wallet/verify}` | `iam-service:8080` + host `4010` |
| 11 | IAM private REST | `/api/v1/me`, `/api/v1/me/{registration,wallets,wallets/*}` (explicit, **not** a `/me/*` catch-all), `/api/v1/auth/change-password`, `/api/v1/{profile,wallets,onboarding,identity}` | `iam-service:8080` + host `4010` |
| 12 | Meter Service | `/api/v1/meters`, `/api/v1/meters/*`, `/api/v1/me/meters` — priority 20, so it outranks IAM route 11 **and** the simulator's `/api/v1/meters` route 41 | `meter-service:8080` |
| 13 | IAM system config (**PRIVATE**) | `/api/v1/system/config` — `ip-restriction` to internal CIDRs only | `iam-service:8080` + host `4010` |
| 2, 20, 21, 22 | Trading REST | `/api/v1/{orders,quotes,zones,stats,futures,analytics,trades,price-alerts,transactions,carbon,settlement,markets/*,...}`; `/api/v1/me/{orders,trades,futures,analytics,transactions,carbon,wallets/*/balance}` carve-out (priority 20) | `trading-service:8093` |
| 3, 30, 31, 32 | Notifications REST | `/api/v1/notifications[/*]` and the `/api/v1/me/notifications` carve-outs (priority 20/21) are rewritten to the upstream's real `/api/v1/noti/*` paths; route 32 passes `/api/v1/noti[/*]` through unchanged | `noti-service:8080` |
| 33 | Notifications WebSocket | `/ws` — websocket route **without** `plugin_config_id: 1` (the shared plugins break the upgrade handshake); noti-service validates the JWT from `?token=` itself | `noti-service:8080` |
| 4, 5, 9, 40, 41, 42 | Smartmeter Simulator | `/api/v1/public/grid-*`, `/public/meters`, `/api/market/ws` (WS→`/ws`), `/simulation`, meters admin, microgrid endpoints | `smartmeter-simulator:8082` + host `12010` |
| 8 | Health, metrics & API-docs (**PRIVATE**) | `/health`, `/metrics`, `/api-docs/openapi.json`, `/scalar` — `ip-restriction` to internal CIDRs only | `iam-service:8080` + host `4010` |
| 100 | IAM gRPC (ConnectRPC) | `/identity.IdentityService/*` | `iam-service:8090` + host `5010` |
| 101 | Trading gRPC (ConnectRPC) | `/trading.TradingService/*` | `trading-service:8092` + host `8092` |
| 50, 51 | Solana JSON-RPC proxy | `/api/v1/rpc` (→ `/`), `/api/v1/rpc-ws` (WS → `/`) — lets browser web3.js reach the host validator | host `8899` / host `8002` only |

### Path-rewrite convention

Client-friendly **`/api/v1/me/...`** paths (the platform-wide user-self namespace) are rewritten via
`proxy-rewrite.regex_uri` to each backend's canonical resource paths (which derive the user from the
injected `x-gridtokenx-user-id` header), e.g.:

- `/api/v1/me/orders` → `/api/v1/orders` (Trading)
- `/api/v1/me/notifications/mark-all-read` → `/api/v1/noti/read-all` (Noti)
- `/api/v1/markets/zones/{z}/order-book` → `/api/v1/zones/{z}/book`

The `/api/v1/me` namespace is **shared across services**: IAM owns the profile/wallet paths (route 11,
explicit list, served natively — no rewrite), while Trading/Noti/Meter own sibling sub-paths via
higher-`priority` carve-out routes so IAM's route never swallows them. (Migrated from the older
`/api/v1/users/me/...` convention.)

## 6. Dual-Upstream Dev Pattern

IAM and simulator upstreams list two round-robin nodes — the in-network container **and**
`host.docker.internal:<host-port>` — so a developer can run one of those services natively while the
rest stay containerized; round-robin reaches whichever is up. In production only the container node
resolves. Trading, Noti, and Meter upstreams are **container-only**, and the Solana RPC proxy routes
(50/51) are host-only, since the validator runs natively on the host.

## 7. Changing Routes / Reloading

Standalone mode has no live admin API. To change routing:

1. Edit `apisix.yaml` (keep the trailing `#END` marker — APISIX requires it).
2. Restart the gateway: `docker compose restart apisix` (or `just orb-rebuild`).

> ⚠️ **Security — dev secrets are committed here.** `apisix.yaml` hardcodes a JWT consumer secret,
> a gateway-secret dev fallback, and a **self-signed dev TLS cert + private key** (the `ssls` block,
> SNI `*.orb.local`/`localhost`, served on `:9443` so OrbStack can proxy `https://`/`wss://`). These
> are **dev defaults only**. For any non-local deployment: move `secret` and
> `GRIDTOKENX_GATEWAY_SECRET` to env/secret management, rotate them, and terminate TLS with a real
> certificate. The downstream services trust `x-gridtokenx-gateway-secret` — if it leaks, identity
> headers can be spoofed.

## 8. Related

| Path | Covers |
| :--- | :--- |
| `../docker-compose.yml` (`apisix:` block) | Image, port mapping, mounts, healthcheck |
| `../gridtokenx-aggregator-bridge/` | IoT/edge ingress (direct Ed25519-signed telemetry; no edge proxy) |
| `../README.md` | Platform port table and gateway overview |
