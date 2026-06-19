# API Design Guide — Webapp + Mobile

> **STATUS: DRAFT — FOR REVIEW ONLY. NOT APPROVED. DO NOT IMPLEMENT.**
> This document proposes guidance for discussion. Nothing here is adopted until reviewed and signed off.
>
> Platform-wide best practices for designing client-facing and internal APIs in GridTokenX.
> Scope: how to design APIs consumed by the webapp, mobile apps, and third-party partners,
> and how those map onto the existing gateway + service-mesh topology.
>
> Last reviewed: 2026-06-18

---

## 0. Principles

- **One backend, many clients.** Do not build a separate "mobile API" and "web API". Build one API; diverge only at the edge (payload shape, field selection).
- **Contract-first.** Define the contract (OpenAPI for REST, `.proto` for gRPC) before writing handlers. Generate client SDKs from it. Hand-written clients drift from the server and cause bugs.
- **Stateless requests.** Every request is self-contained — the token carries identity. Enables horizontal scaling and survives restarts.
- **Gateway owns cross-cutting concerns.** Auth pre-check, rate-limiting, CORS, versioning, and request-id live at the APISIX gateway. Services stay focused on business logic.

---

## 1. Topology

```
[webapp]  [mobile]  [partner]
        │  HTTPS REST/JSON
   APISIX gateway (:4001)   ← auth, rate-limit, CORS, version-gate, request-id
        │  gRPC / ConnectRPC (mesh, :5000s)
   IAM · Trading · Noti · Meter · Aggregator Bridge
        │
   Postgres · Redis · NATS/Kafka
```

- Clients hit the **gateway only**. They never touch internal service ports.
- Service-to-service traffic uses **gRPC/ConnectRPC** on the mesh.
- Public client traffic uses **REST/JSON**.

---

## 2. Protocol choice

| Need | Use |
|------|-----|
| Public client API (web, mobile, partner) | **REST + JSON** — universal, cacheable, debuggable |
| Service ↔ service | **gRPC / ConnectRPC** — typed, fast (IAM `IdentityService` already does this) |
| Mobile bandwidth-tight, many response shapes | GraphQL (optional; adds gateway + caching complexity) |
| Realtime push | WebSocket / SSE for web; FCM / APNs for mobile |

**Default:** REST public, gRPC internal. Do not expose gRPC-web directly to mobile — old app versions make it fragile.

---

## 3. Resource design (REST)

- Nouns, not verbs: `POST /orders`, not `/createOrder`.
- Plural collections: `/users/{id}/wallets`.
- Hierarchy expresses ownership: `/api/v1/me/wallets/{id}`.
- HTTP verbs mean what they mean: `GET` safe, `PUT` idempotent full-replace, `PATCH` partial, `DELETE` removes.
- Honest status codes: `200/201/204`, `400/401/403/404/409/422`, `429`, `5xx`.
- Filtering / sort / pagination in query string: `?status=open&sort=-created&cursor=abc`.

---

## 4. Authentication & tokens

Core flow:

```
login → access JWT (~15m) + refresh token (rotating)
access expires → exchange refresh → new access + refresh pair
refresh reuse detected → revoke the entire token family (theft signal)
```

Token storage by client:

| Client | Access token | Refresh token storage |
|--------|--------------|------------------------|
| Webapp | JWT, ~15 min | `httpOnly Secure SameSite` cookie (blocks XSS theft) |
| Mobile | JWT, ~15 min | OS secure store — iOS Keychain / Android Keystore (never plain prefs) |
| Partner / server | API key | Revocable, stored in IAM |

- Gateway verifies the token once (IAM `VerifyToken` RPC) and injects `x-user-id` + `x-gridtokenx-role` headers downstream. Services trust gateway-injected headers and **fail closed** on missing/unknown role.
- Maintain a Redis blocklist for instant logout / revocation (IAM already has a Redis cache).

---

## 5. Versioning

- URL-based version: `/api/v1/...`. Once shipped, **freeze it** — never remove or rename a field.
- Evolve additively. A breaking change becomes `/api/v2`.
- **Mobile reality:** app-store review + user upgrade lag means old client versions stay live for **months**, and you cannot force a silent update. Backward compatibility is mandatory.
- Send `X-App-Version` from mobile clients → gateway returns `426 Upgrade Required` for clients too old to support.

---

## 6. Mobile-specific concerns

- **Thin payloads** — separate `/summary` vs `/detail` endpoints, or support sparse field selection. Saves battery and mobile data.
- **Cursor-based pagination** — not offset (offset shifts under concurrent inserts).
- **Idempotency** — accept an `Idempotency-Key` header on `POST` so retries on flaky networks are safe.
- **Offline-first** — client queues writes locally and replays them with idempotency keys.
- **Push, not poll** — deliver updates via Noti service → FCM / APNs.
- **Retry with backoff + jitter** on the client; gateway rate-limiting shields the backend.
- **Compression** — gzip / brotli on responses.

---

## 7. Performance

- **Caching** — `ETag` / `Cache-Control` for `GET`; CDN for static; Redis for hot data.
- **Avoid N+1** — provide batch/include endpoints, or GraphQL where shapes vary widely.
- **Always paginate** — never return an unbounded list.
- **Async heavy work** — push to a queue, return `202 Accepted` + a status URL.

---

## 8. Error contract

Stable error envelope across all services:

```json
{
  "error": {
    "code": "AUTH_TOKEN_EXPIRED",
    "message": "human-readable text",
    "request_id": "uuid",
    "details": []
  }
}
```

- `code` is a stable machine string — clients branch on it and it must never change meaning. `message` is free to reword.
- Always include `request_id` for trace correlation.
- Validation failures return field-level entries in `details`.
- Use `thiserror` typed errors at the API boundary (platform convention) and map them to HTTP status + `code`.

---

## 9. Security baseline

- HTTPS only; enable HSTS.
- Rate-limit per-user **and** per-IP at the gateway.
- Validate all input server-side — never trust the client.
- CORS: explicit origin allowlist (no `*` when credentials are allowed).
- Secrets in vault / env, never in code.
- Least-privilege RBAC per endpoint.
- Audit-log authentication events.

---

## 10. Operations & lifecycle

- `/health` (live + ready) and `/metrics` (Prometheus) — internal CIDRs only.
- Structured JSON logs with request-id propagation (tracing / OTel).
- Deprecation: send a `Sunset` header, document it, and watch usage dashboards before removing.
- CI gates: spec-vs-implementation check, contract tests, lint.

---

## Build order

1. Write the OpenAPI / `.proto` contract.
2. Generate client SDKs (TypeScript for web, Swift / Kotlin for mobile).
3. Configure the gateway: auth pre-check + rate-limit + version-gate.
4. Implement resource endpoints — thin handlers delegating to the service layer.
5. Add the error envelope + request-id propagation.
6. Wire health / metrics / structured logs.
7. Add contract tests to CI.

---

## How this maps to GridTokenX today

- **Gateway:** APISIX at `:4001` (user-facing); API orchestrator at `:4000`.
- **Auth:** IAM issues JWT + API keys; gRPC `VerifyToken` / `Authorize` / `VerifyApiKey` back the gateway pre-check. RBAC via `x-gridtokenx-role` header, fail-closed.
- **User-self surface:** `/api/v1/me/*` — sibling owners (Trading, Noti, Meter) are gateway-rewritten to their services.
- **Internal mesh:** ConnectRPC contracts (`crates/iam-protocol/proto/identity.proto`).
- **Ops surface:** `/health`, `/metrics`, `/api/v1/system/config` gated to internal CIDRs via APISIX `ip-restriction`.
