# envoy_conf — Architecture

> Envoy configuration for the **edge gateway** — the IoT/mTLS entry point for devices (smart
> meters), counterpart to the user-facing APISIX gateway. Runs as a container defined in the root
> `docker-compose.yml`; this folder holds only its mounted config. This doc covers **only** the
> contents of this folder.

---

## 1. What This Is

Envoy is intended as the **device/edge gateway** (`:4002`) — terminating mutual TLS from IoT
hardware and forwarding verified traffic to Oracle Bridge. It is the IoT-side counterpart to
**APISIX** (`apisix_conf/`, user-facing `:4001`).

> ⚠️ **Current state: dev stub, not a real edge.** The checked-in `envoy.yaml` is a **minimal
> bring-up stub**. It exists because docker had auto-created an empty directory where the file
> bind-mount expected a file, which breaks container start. The stub lets Envoy boot so the rest of
> the stack comes up — it does **not** implement mTLS, device auth, or real routing. **Replace
> before relying on the `:4002` edge path.**

## 2. Files

| File | Role |
| :--- | :--- |
| `envoy.yaml` | Minimal dev stub — admin listener + one edge listener that returns `200 "ok"` |

Bind-mounted read-only into the container (from `docker-compose.yml`):

```
./envoy_conf/envoy.yaml → /etc/envoy/envoy.yaml
```

## 3. What the Stub Actually Does

| Listener | Address | Behavior |
| :--- | :--- | :--- |
| `admin` | `0.0.0.0:9901` | Envoy admin / `GET /ready` healthcheck |
| `edge` | `0.0.0.0:10000` | HTTP connection manager; **every** path `/` → `direct_response 200 "ok"` |

No upstream clusters, no TLS, no auth — it terminates nothing and routes nowhere.

## 4. Ports (from `docker-compose.yml`)

| Host | Container | Purpose |
| :--- | :--- | :--- |
| `4002` | `10000` | Edge proxy (device entry) |
| `8002` | `9901` | Envoy admin |

Healthcheck: `curl -f http://localhost:9901/ready`.

## 5. To Make This a Real Edge Gateway

Replace the stub with config that:

1. **Terminates mTLS** — `transport_socket` with `DownstreamTlsContext`, `require_client_certificate:
   true`, and a CA bundle for device certs (per-device identity).
2. **Routes to Oracle Bridge** — define an upstream cluster for the bridge ingest endpoint instead
   of `direct_response`.
3. **Preserves device identity** — forward the client-cert subject downstream so Oracle Bridge can
   tie traffic to a device before Ed25519 verification.

> Device telemetry integrity ultimately rests on **Ed25519 signatures verified at Oracle Bridge**;
> the edge mTLS here is transport-level defense-in-depth, not the integrity guarantee.

## 6. Related

| Path | Covers |
| :--- | :--- |
| `../apisix_conf/ARCHITECTURE.md` | The other gateway — user-facing (APISIX, `:4001`) |
| `../docker-compose.yml` (`envoy:` block) | Image, ports, mount, healthcheck |
| `../gridtokenx-oracle-bridge/` | The intended upstream — telemetry verification + ingest |
