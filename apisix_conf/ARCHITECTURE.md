# apisix_conf — Architecture

> Apache APISIX configuration for the **user-facing gateway** — the single public HTTP entry point
> for web clients (trading portal, explorer). Runs as a container defined in the root
> `docker-compose.yml`; this folder holds only its mounted config. This doc covers **only** the
> contents of this folder + how the gateway is wired.

---

## 1. What This Is

APISIX is the **public internet gateway** for the Exchange platform. All browser/app traffic enters
here, gets authenticated, has identity headers injected, and is fan-routed to the backend services
(IAM, Trading, Noti, Smartmeter Simulator). It is the counterpart to **Envoy** (`envoy_conf/`),
which handles the IoT/mTLS edge.

Runtime: `apache/apisix:3.15.0-debian`, **standalone mode** (`APISIX_STAND_ALONE=true`) — APISIX
reads routes from a static YAML file instead of etcd. No control plane, no admin API in practice;
edit the YAML and restart.

## 2. Files

| File | Role |
| :--- | :--- |
| `config.yaml` | APISIX runtime config — `data_plane` role, `config_provider: yaml`, `node_listen: 9080`, websocket enabled |
| `apisix.yaml` | The declarative data plane: `plugin_configs`, `routes`, `consumers` |

Both are bind-mounted read-only into the container:

```
./apisix_conf/apisix.yaml → /usr/local/apisix/conf/apisix.yaml
./apisix_conf/config.yaml → /usr/local/apisix/conf/config.yaml
```

## 3. Ports (from `docker-compose.yml`)

| Host | Container | Purpose |
| :--- | :--- | :--- |
| `4001` | `9080` | **User proxy HTTP** (the public entry point) |
| `8443` | `9443` | User proxy HTTPS |
| `8001` | `9180` | Admin HTTP (unused in standalone) |

Internally other services reach it as `http://apisix:9080`.

## 4. Auth & Identity Injection

Central shared `plugin_config` **id 1** ("Shared JWT auth + user-id extraction + CORS") is attached
to every authenticated route via `plugin_config_id: 1`:

1. **`jwt-auth`** (`store_in_ctx: true`) — validates the bearer JWT against the `consumers` table.
2. **`serverless-post-function`** (access phase) — pulls `sub` from the JWT payload and injects
   downstream identity headers:
   - `x-gridtokenx-user-id: <sub>`
   - `x-gridtokenx-role: api-gateway`
   - `x-gridtokenx-gateway-secret: $GRIDTOKENX_GATEWAY_SECRET` (env, dev fallback hardcoded)
3. **`cors`** — permissive CORS.

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

Routes are grouped by backend. Each upstream is **dual-node round-robin**: the container DNS name
**and** `host.docker.internal` — so the same config works whether the backend runs in Docker or
natively on the host during dev (see §6).

| ID(s) | Service | Path prefix(es) | Upstream |
| :--- | :--- | :--- | :--- |
| 10 | IAM public REST | `/api/v1/auth/{login,register,verify,forgot,reset}`, `/api/v1/system/config` | `iam-service:8080` / host `4010` |
| 11, 110 | IAM private REST | `/api/v1/{profile,me,wallets,onboarding,identity,meters}`, `users/me→me` | `iam-service:8080` / host `4010` |
| 2, 20, 21, 22 | Trading REST | `/api/v1/{orders,quotes,zones,stats,futures,analytics,trades,settlement,carbon,...}` | `trading-service:8093` / host `8093` |
| 3, 30, 31 | Notifications | `/api/v1/notifications/*`, `/ws`, `users/me/notifications→notifications` | `noti-service:8080` / host `5050` |
| 4, 5, 9, 40, 41, 42 | Smartmeter Simulator | `/api/v1/public/grid-*`, `/public/meters`, `/api/market/ws`, `/simulation`, microgrid | `smartmeter-simulator:8080` / host `12010` |
| 8 | Health & metrics | `/health`, `/metrics` | `iam-service:8080` / host `4010` |
| 100 | IAM gRPC (ConnectRPC) | `/identity.IdentityService/*` | `iam-service:8090` / host `5010` |
| 101 | Trading gRPC (ConnectRPC) | `/trading.TradingService/*` | `trading-service:8092` / host `8092` |

### Path-rewrite convention

Client-friendly **`/api/v1/users/me/...`** paths are rewritten via `proxy-rewrite.regex_uri` to the
backend's canonical resource paths (which derive the user from the injected `x-gridtokenx-user-id`
header), e.g.:

- `/api/v1/users/me/orders` → `/api/v1/orders`
- `/api/v1/users/me/notifications/mark-all-read` → `/api/v1/notifications/read-all`
- `/api/v1/markets/zones/{z}/order-book` → `/api/v1/zones/{z}/book`

## 6. Dual-Upstream Dev Pattern

Every upstream lists two nodes — the in-network container and `host.docker.internal:<host-port>` —
both weight 1. This lets a developer run one service natively (e.g. `trading-service` on `:8093`)
while the rest stay containerized; round-robin reaches whichever is up. In production only the
container node resolves.

## 7. Changing Routes / Reloading

Standalone mode has no live admin API. To change routing:

1. Edit `apisix.yaml` (keep the trailing `#END` marker — APISIX requires it).
2. Restart the gateway: `docker compose restart apisix` (or `just orb-rebuild`).

> ⚠️ **Security — dev secrets are committed here.** `apisix.yaml` hardcodes a JWT consumer secret
> and a gateway-secret dev fallback; `config.yaml`/routes carry no TLS. These are **dev defaults
> only**. For any non-local deployment: move `secret` and `GRIDTOKENX_GATEWAY_SECRET` to env/secret
> management, rotate them, and front the gateway with TLS. The downstream services trust
> `x-gridtokenx-gateway-secret` — if it leaks, identity headers can be spoofed.

## 8. Related

| Path | Covers |
| :--- | :--- |
| `../docker-compose.yml` (`apisix:` block) | Image, port mapping, mounts, healthcheck |
| `../envoy_conf/` | The other gateway — IoT/mTLS edge (Envoy, `:4002`) |
| `../README.md` | Platform port table and gateway overview |
