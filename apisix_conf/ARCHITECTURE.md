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
| `config.yaml` | APISIX runtime config — `data_plane` role, `config_provider: yaml`, `node_listen: 9080`, websocket enabled, SSL listener on `9443`, `dns_resolver_valid: 30` (see §6) |
| `apisix.yaml` | The declarative data plane: `plugin_configs`, `upstreams`, `routes`, `ssls`, `consumers` |
| `certs/` | Raw dev TLS cert/key files (gitignored); their PEMs are inlined into the `ssls` block of `apisix.yaml` |
| `ui/config.yaml` | Config for the **dev-only Dashboard mirror** (`apisix-ui` compose service, profile `ui`) — traditional mode + etcd, serves the embedded Dashboard over a mirror of `apisix.yaml` (see §3) |

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

Internally other services reach it as `http://apisix:9080`.

> **No Admin API, no Dashboard on the gateway itself.** File-driven standalone mode
> (`role: data_plane`, `config_provider: yaml`) disables the Admin API entirely — nothing listens on
> `9180`, so the embedded Dashboard (`/ui/`, APISIX 3.13+) cannot run in this deployment (verified:
> connection refused on `127.0.0.1:9180` inside the container). API-driven standalone doesn't help
> either: the Dashboard's SPA calls the per-resource CRUD endpoints, which 404 in that mode
> (verified empirically on `3.15.0-debian`). A functioning Dashboard requires traditional mode +
> etcd — which is exactly what the **dev-only UI mirror** provides (see below). For read-only
> inspection of the *live* gateway use the container-internal Control API on `:9090` (see §6).

### Dev-only Dashboard mirror (`apisix-ui`, compose profile `ui`)

Because the Dashboard can't run on the gateway, an optional **mirror** pair exists in
`docker-compose.yml`: `apisix-ui` (same APISIX image, traditional mode, config in `ui/config.yaml`)
backed by `apisix-ui-etcd` (throwaway etcd, no volume). `scripts/sync-apisix-ui.sh` converts
`apisix.yaml` to JSON (via a `mikefarah/yq` container — no host deps) and PUTs every resource
through the mirror's Admin API.

```bash
just apisix-ui        # start mirror + etcd (off by default) and push apisix.yaml
just apisix-ui-sync   # re-push after editing apisix.yaml (idempotent)
just apisix-ui-down   # stop the mirror
# then browse http://localhost:8001/ui/ — admin key: gridtokenx-ui-admin-dev
```

(The recipes wrap `docker compose --profile ui …` + `scripts/sync-apisix-ui.sh`; the script waits
for the mirror's Admin API before pushing, so a cold `just apisix-ui` is a single command.)

Rules: **`apisix.yaml` stays the single source of truth** — Dashboard edits touch only the mirror
and are lost on the next sync; re-run the sync script after every `apisix.yaml` change you want to
browse. The mirror's etcd is deliberately ephemeral (restart → empty → re-sync). Admin/Dashboard
port `8001` binds to `127.0.0.1` only. No production traffic ever routes through the mirror.

The Dashboard's **Stream Routes** tab returns `400 {"error_msg":"stream mode is disabled, can not
add stream routes"}` (and a matching `[warn]` at `init.lua:182` in the mirror's log). **This is
expected, not a fault** — the gateway is HTTP/WebSocket only, with no L4 stream routes in
`apisix.yaml` and no `apisix.stream_proxy` in either config. The Dashboard SPA renders a tab per
resource type regardless of what the instance enables, and APISIX's message says "add" even for a
read. Stream mode is left off on the mirror deliberately: enabling it would let someone create a
stream route in the UI that could never exist in the real gateway.

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
4. **`limit-count`** — per-consumer gateway rate limit (1200 / 60s, `429` on exceed). Keyed on
   `$http_authorization` (the raw bearer JWT) — **not** `x-gridtokenx-user-id`, because the
   `serverless-post-function` that sets that header runs *after* `limit-count` in the access phase
   (empty key → one global bucket). Keying on the always-present Authorization header gives a
   per-token (≈ per-session) bucket. `policy: local` (per-node in-memory, single data-plane node);
   `allow_degradation: true` fails **open** so a limiter fault never 500s a legitimate request. The
   ceiling is deliberately high so it only catches abuse, never dev/e2e bursts. Public/unauth routes
   (login/register/verify) are **not** gateway-limited — IAM self-limits those per-IP/endpoint.

The single configured consumer:

```yaml
consumers:
  - username: gridtokenx_user
    plugins:
      jwt-auth:
        key: "gridtokenx-iam-service"
        secret: ${{JWT_SECRET}}   # env-interpolated — must equal IAM's JWT_SECRET
```

The secret is **read from the environment** (`JWT_SECRET`, passed to the container in
`docker-compose.yml`), not inlined — a literal here once silently drifted from `.env` and every
gateway-authenticated route 401'd with "failed to verify jwt" while the services themselves were
healthy. IAM signs (HS256, `iss: gridtokenx-iam-service`); this consumer verifies.

Public/unauthenticated routes (login, register, verify, password reset, system config, public grid/
meter reads, health) use `proxy-rewrite` to set the gateway headers directly **without** JWT.

## 5. Routing

Routes are grouped by backend:

Routes carry no inline `upstream:` block — each references a shared definition in the top-level
`upstreams:` list by `upstream_id` (the "Upstream" column below is that id). The node lists were
byte-identical across all 25 routes before, so health-check policy had nowhere single to live.

| ID(s) | Service | Path prefix(es) | Upstream (`upstream_id` → node(s)) |
| :--- | :--- | :--- | :--- |
| 10 | IAM public REST | `/api/v1/auth/{login,register,verify,forgot,reset,logout,refresh,resend-verification,wallet/verify}` | `iam` — `iam-service:8080` + host `4010` |
| 11 | IAM private REST | `/api/v1/me`, `/api/v1/me/{registration,wallets,wallets/*}` (explicit, **not** a `/me/*` catch-all), `/api/v1/auth/change-password`, `/api/v1/{profile,wallets,onboarding,identity}` | `iam` — `iam-service:8080` + host `4010` |
| 12 | Meter Service | `/api/v1/me/meters`, `/api/v1/me/meters/*` (canonical caller-scoped surface), plus `/api/v1/meters`, `/api/v1/meters/*` (dual-served legacy aliases + the grid-wide `/meters/map`) — priority 20, so it outranks IAM route 11 **and** the simulator's `/api/v1/meters` route 41 | `meter` — `meter-service:8080` |
| 13 | IAM system config (**PRIVATE**) | `/api/v1/system/config` — `ip-restriction` to internal CIDRs only | `iam` — `iam-service:8080` + host `4010` |
| 2, 20, 21, 22 | Trading REST | `/api/v1/{orders,quotes,zones,stats,futures,analytics,trades,price-alerts,transactions,carbon,settlement,markets/*,...}`; `/api/v1/me/{orders,trades,futures,analytics,transactions,carbon,wallets/*/balance}` carve-out (priority 20) | `trading` — `trading-service:8093` |
| 6 | Trading public active-order meters | `/api/v1/public/active-order-meters` — no auth (no `plugin_config_id`); returns only order *presence* per meter (strictly less than the public order book) so the grid map can hide non-trading meters for logged-out viewers. Backend serves this exact path — no rewrite | `trading` — `trading-service:8093` |
| 23 | Trading market-data WebSocket | `/ws/trading?token=&zone_id=` — websocket route **without** `plugin_config_id: 1` (same handshake constraint as route 33); trading-api's `ws_handler` validates the JWT from `?token=` itself. Streams per-zone sequenced order/settlement frames off Kafka | `trading` — `trading-service:8093` |
| 3, 30, 31, 32 | Notifications REST | `/api/v1/notifications[/*]` and the `/api/v1/me/notifications` carve-outs (priority 20/21) are rewritten to the upstream's real `/api/v1/noti/*` paths; route 32 passes `/api/v1/noti[/*]` through unchanged | `noti` — `noti-service:8080` |
| 33 | Notifications WebSocket | `/ws` — websocket route **without** `plugin_config_id: 1` (the shared plugins break the upgrade handshake); noti-service validates the JWT from `?token=` itself | `noti` — `noti-service:8080` |
| 4, 5, 9, 40, 41, 42 | Smartmeter Simulator | `/api/v1/public/grid-*`, `/public/meters`, `/api/market/ws` (WS→`/ws`), `/simulation`, meters admin, microgrid endpoints | `simulator` — `smartmeter-simulator:8082` + host `12010` |
| 8 | Health, metrics & API-docs (**PRIVATE**) | `/health`, `/metrics`, `/api-docs/openapi.json`, `/scalar` — `ip-restriction` to internal CIDRs only | `iam` — `iam-service:8080` + host `4010` |
| 100 | IAM gRPC (ConnectRPC) (**PRIVATE**) | `/identity.IdentityService/*` — `ip-restriction` to internal CIDRs only; mesh calls `iam-service:8090` directly | `iam-grpc` — `iam-service:8090` + host `5010` |
| 101 | Trading gRPC (ConnectRPC) (**PRIVATE**) | `/trading.TradingService/*` — `ip-restriction` to internal CIDRs only; mesh calls `trading-service:8092` directly | `trading-grpc` — `trading-service:8092` + host `8092` |
| 50, 51 | Solana JSON-RPC proxy | `/api/v1/rpc` (→ `/`), `/api/v1/rpc-ws` (WS → `/`) — lets browser web3.js reach the host validator | `solana-rpc` / `solana-ws` — host `8899` / host `8002` only |

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

## 6. Upstreams: Dev Fallbacks, Health Checks, DNS

### Dual-upstream dev pattern

The `iam` and `simulator` upstreams list two round-robin nodes — the in-network container **and**
`host.docker.internal:<host-port>` — so a developer can run one of those services natively while the
rest stay containerized. In production only the container node resolves. `trading`, `noti`, and
`meter` are **container-only**; `solana-rpc`/`solana-ws` are host-only, since the validator runs
natively on the host.

### Active health checks

`iam`, `trading`, `meter`, and `noti` share one `active` HTTP check policy (YAML anchor: probe
`/health`, timeout 2s; 5s interval when healthy, 3s when not; 2 consecutive failures ejects a node,
1 success restores it). Without them, round-robin fed traffic to any node that merely *resolved* —
most visibly the dev fallbacks above, which took ~50% of requests whether or not anything was
listening on the host port. "Round-robin reaches whichever is up" only became true once these
existed.

`simulator` carries its own, looser check: path `/api/v1/quality/health` (its `/health` 404s;
this path matches the container's own docker healthcheck), **timeout 5s** and **3 timeouts** to
eject at a 5s unhealthy interval. Measured 2026-07-29: the endpoint's median is well under 100ms
but its latency tail reaches ~2s, so the shared 2s timeout tripped the unhealthy counter and
flapped both nodes even though every probe eventually returned 200. Re-measure before tightening.

`http_path` must be a route the node actually serves — **a 404 marks every node down and takes the
service off the gateway**. Verify a 200 before enabling one.

The gRPC (`iam-grpc`, `trading-grpc`) and Solana upstreams have **no** active check — they expose no
plain-HTTP health route, and a check against the wrong path is worse than none.

Inspect live state via the control API (container-internal, not exposed):

```bash
docker run --rm --network container:gridtokenx-apisix curlimages/curl \
  -s http://127.0.0.1:9090/v1/healthcheck
```

### DNS: why `dns_resolver_valid` exists

Upstream nodes are container **names**, and `docker compose up` recreates a container on a new IP.
APISIX re-resolves per request (`apisix/init.lua:246`), but when resolution fails
`parse_domain_for_nodes` returns an **empty node list rather than an error**
(`apisix/utils/upstream.lua:83`) and the caller persists that empty list — every later request then
503s with `no valid upstream node` until something re-resolves successfully.

On 2026-07-28 a `trading-service` recreate left every trading route 503ing for ~70 minutes; only an
APISIX restart cleared it. **Active health checks do not cover this** — with zero resolved nodes
there is nothing to probe. `dns_resolver_valid: 30` in `config.yaml` bounds the stale window to 30s
by capping how long a resolved address is trusted (default is the record's own TTL, which Docker's
embedded DNS hands out as 600s). It reaches the Lua DNS client as `opts.validTtl`
(`apisix/core/utils.lua:101`).

## 7. Changing Routes / Reloading

Standalone mode has no live admin API. To change routing:

1. Edit `apisix.yaml` (keep the trailing `#END` marker — APISIX requires it).
2. Reload the gateway: `docker compose up -d --force-recreate apisix`.

> ⚠️ **`docker compose restart apisix` is not always enough.** Both YAML files are bind-mounted as
> *individual files*, so the mount tracks an **inode**, not a path. Any editor that writes via
> temp-file-plus-rename (most of them, and every agentic edit tool) gives the file a new inode and
> leaves the container's mount dangling — `ls -l` inside shows `-????????? ? ? ?` and APISIX keeps
> serving the config it loaded at boot. `restart` reuses the same mount namespace and does **not**
> re-bind; only recreating the container does. Confirm the mount is live before trusting a reload:
>
> ```bash
> docker exec -u 0 gridtokenx-apisix ls -l /usr/local/apisix/conf/apisix.yaml
> ```
>
> A `sed -i` / in-place truncate preserves the inode and survives a plain `restart` — which is why
> this trap is intermittent rather than constant.

> ⚠️ **Security — dev secrets are committed here.** `apisix.yaml` hardcodes a gateway-secret dev
> fallback (`gridtokenx-gateway-secret-2025`, both in the serverless function and inline on the
> public routes) and a **self-signed dev TLS cert + private key** (the `ssls` block, SNI
> `*.orb.local`/`localhost`, served on `:9443` so OrbStack can proxy `https://`/`wss://`). The JWT
> consumer secret is already env-injected (`${{JWT_SECRET}}` — see §4). These are **dev defaults
> only**. For any non-local deployment: move `GRIDTOKENX_GATEWAY_SECRET` to env/secret management,
> rotate both secrets, and terminate TLS with a real certificate. The downstream services trust
> `x-gridtokenx-gateway-secret` — if it leaks, identity headers can be spoofed.

## 8. Related

| Path | Covers |
| :--- | :--- |
| `../docker-compose.yml` (`apisix:` block) | Image, port mapping, mounts, healthcheck |
| `../docker-compose.yml` (`apisix-ui:` / `apisix-ui-etcd:` blocks) | Dev-only Dashboard mirror (profile `ui`, see §3) |
| `../scripts/sync-apisix-ui.sh` | Pushes `apisix.yaml` into the Dashboard mirror via its Admin API |
| `../gridtokenx-aggregator-bridge/` | IoT/edge ingress (direct Ed25519-signed telemetry; no edge proxy) |
| `../README.md` | Platform port table and gateway overview |
