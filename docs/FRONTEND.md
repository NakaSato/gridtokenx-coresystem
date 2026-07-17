# Frontend

GridTokenX has frontend applications living in their own submodules. This doc indexes them and
states the shared conventions; per-app detail lives in each app's own README.

## Applications

| App | Submodule | Stack | Purpose |
| :--- | :--- | :--- | :--- |
| Trading UI | `gridtokenx-trading/` | Next.js | P2P trading portal — order book, wallet, settlement views |
| Explorer | `gridtokenx-explorer/` | Next.js | Blockchain explorer for accounts, tx, and energy assets |

## How Frontends Reach the Backend

- **All traffic goes through APISIX** `:4001` — never directly to service ports.
- The trading frontend calls the backend over **plain REST/JSON** (`fetch` against `/api/v1/*`),
  **not** ConnectRPC. (ConnectRPC is used inside the mesh and on the gateway's gRPC routes
  — e.g. `IdentityService` `:5010`, `TradingService` `:5020` (container 8092) — but the browser
  client speaks REST.)
- Live updates (order book, market, telemetry) arrive over **WebSocket** (reconnecting client),
  plus external price streams (Pyth / TradingView) where applicable.

## Wallet Model (hybrid — read carefully)

GridTokenX runs **two wallet models** at once; do not collapse them:

- **Backend custodial wallets** — IAM provisions and holds an encrypted custodial key per user (OWS
  file vault). Used for platform-side settlement and energy-token minting. The frontend never sees
  these keys. See [`product-specs/new-user-onboarding.md`](product-specs/new-user-onboarding.md).
- **Frontend non-custodial wallets** — the trading UI also wires browser Solana wallet adapters
  (Phantom / Solflare / Trust / SafePal) and an Anchor `Program`; on-chain contract transactions are
  signed **in the user's own wallet**, client-side. The only secret the frontend persists is the
  backend JWT (web storage).

## Conventions

- Backend contract for the browser is **REST/JSON** over `/api/v1/*` — verify route shapes against
  the APISIX config ([`../apisix_conf/ARCHITECTURE.md`](../apisix_conf/ARCHITECTURE.md)).
- Never embed service-mesh ports in frontend config; the gateway is the only public surface.
- Don't claim wallets are purely custodial — the trading frontend signs client-side via wallet
  adapters (see Wallet Model above).

## Index

_Add per-feature frontend specs here as they are written. Product behavior lives in_
_[`product-specs/`](product-specs/)._
