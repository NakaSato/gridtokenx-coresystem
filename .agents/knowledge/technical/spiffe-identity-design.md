# SPIFFE Identity Design

This document formalizes the Secure Production Identity Framework for Everyone (SPIFFE) naming scheme and the end-to-end authorization matrix for the GridTokenX ecosystem.

## Identity Naming Scheme

All internal services in the GridTokenX platform utilize SPIFFE identities for mutual TLS (mTLS) authentication and fine-grained authorization (Service Mesh).

### Trust Domain
`gridtokenx.th`

### Path Structure
`spiffe://gridtokenx.th/{env}/{service}/{role}`

- **env**: The deployment environment (`prod`, `staging`, `dev`).
- **service**: The logical name of the microservice.
- **role** (optional): A differentiator for services with multiple operational modes (e.g., `api` vs `matcher`).

### Identity Inventory (Production)

| Service | Role / Component | SPIFFE ID |
| :--- | :--- | :--- |
| **IAM Service** | Primary | `spiffe://gridtokenx.th/prod/iam-service` |
| **Trading Service** | API Surface | `spiffe://gridtokenx.th/prod/trading-service/api` |
| **Trading Service** | Matching Engine | `spiffe://gridtokenx.th/prod/trading-service/matcher` |
| **Aggregator Bridge** | Primary | `spiffe://gridtokenx.th/prod/aggregator-bridge` |
| **Telemetry Ingest** | Primary | `spiffe://gridtokenx.th/prod/telemetry-ingest` |
| **Chain Bridge** | Primary | `spiffe://gridtokenx.th/prod/chain-bridge` |
| **Compliance Service** | Primary | `spiffe://gridtokenx.th/prod/compliance-service` |
| **Treasury Service** | Primary | `spiffe://gridtokenx.th/prod/treasury-service` |
| **Mint Service** | Primary | `spiffe://gridtokenx.th/prod/mint-service` |
| **Burn Service** | Primary | `spiffe://gridtokenx.th/prod/burn-service` |
| **Reserve Service** | Primary | `spiffe://gridtokenx.th/prod/reserve-service` |
| **Reconciliation** | Primary | `spiffe://gridtokenx.th/prod/reconciliation-service` |
| **Reporting** | Primary | `spiffe://gridtokenx.th/prod/reporting-service` |
| **Edge Gateway** | Envoy Proxy | `spiffe://gridtokenx.th/prod/edge-gateway` |

---

## Authorization Policy Matrix

GridTokenX operates on a **Zero-Trust** basis. Communication is permitted only when an explicit domain-driven justification exists.

### Core Trading Domain

| Source | Destination | Purpose |
| :--- | :--- | :--- |
| `APISIX` (Edge) | `trading-service/api` | User-initiated trading requests |
| `reporting-service` | `trading-service/api` | Read-only administrative queries |
| `trading-service/api` | `iam-service` | User context validation |
| `trading-service/api` | `chain-bridge` | User-signed transaction submission |
| `trading-service/api` | `compliance-service` | Pre-trade risk checks |
| `trading-service/api` | `trading-service/matcher` | Trade command submission |
| `settlement-service` | `trading-service/matcher` | Settlement coordination |

### Oracle & Telemetry Domain

| Source | Destination | Purpose |
| :--- | :--- | :--- |
| `edge-gateway` | `telemetry-ingest` | Meter data ingest (mTLS) |
| `aggregator-bridge` | `chain-bridge` | Attestation submission |
| `reporting-service` | `aggregator-bridge` | Attestation state queries |
| `compliance-service` | `aggregator-bridge` | Data validation checks |

### Chain & gTHB Issuer Domain

| Source | Destination | Purpose |
| :--- | :--- | :--- |
| `trading-service/api` | `chain-bridge` | User transaction submission |
| `trading-service/matcher`| `chain-bridge` | Settlement execution |
| `mint-service` | `chain-bridge` | Token minting |
| `burn-service` | `chain-bridge` | Token burning |
| `reserve-service` | `chain-bridge` | Reserve attestation update |
| `reporting-service` | `chain-bridge` | Read-only chain state queries |
| `mint-service` | `multisig-coordinator`| Approval orchestration |
| `mint-service` | `compliance-service` | KYC/AML check |
| `mint-service` | `treasury-service` | Payment verification |

### Identity & Reporting Domain

| Source | Destination | Purpose |
| :--- | :--- | :--- |
| (Any Service) | `iam-service` | User lookup (Read-only) |
| `APISIX` (Edge) | `iam-service` | Registration / Profile mgmt |
| `compliance-service` | `iam-service` | Account status updates |
| `reporting-service` | (Any Service) | Query endpoints for report generation |

---

## Operation & Enforcement

### Posture
- **Default Deny**: All service-to-service communication is blocked unless an `AuthorizationPolicy` exists.
- **Mutual TLS**: Required for all internal traffic, anchored by the SPIRE workload API.

### Rollout Strategy
1. **Permissive Mode**: Deploy policies with `action: AUDIT` or `dry-run: true` to observe violations.
2. **Analysis**: Use `istioctl analyze` and sidecar logs to verify legitimate traffic.
3. **Enforcement**: Switch to `action: ALLOW` and ensure the global-deny policy is active.
