# gTHB Issuer Service

> Specification for the **gTHB** issuer — a fully-reserved Thai Baht (THB) stablecoin minted on
> GridChain. Covers the issuance/redemption contract, the service decomposition, the compliance and
> reserve guarantees, and the phased rollout.

gTHB is a fiat-collateralized stablecoin: every on-chain token is backed 1:1 by THB held in
regulated bank reserves. The issuer service is the trusted boundary between the Thai banking system
(SCB, KBank, TMB) and GridChain. It mints gTHB when fiat is received and KYC clears, burns gTHB
before releasing fiat, and proves at all times that reserves cover supply.

---

## 1. Architectural Invariants (never bend)

These are the contract. A change that violates one is a defect regardless of how clean it is.

1. **Mint atomicity** — a mint completes **only if** THB received **AND** KYC passed **AND** multisig
   approved **AND** on-chain mint succeeded. Any failed precondition aborts the whole mint.
2. **Burn-before-wire** — a burn completes **only if** the on-chain burn is confirmed **before** the
   THB wire is queued. Fiat never leaves ahead of the token destruction.
3. **Supply ≤ reserves** — on-chain `total_supply` ≤ last attested reserves at all times.
4. **Accounting identity** — `sum(confirmed mints) − sum(confirmed burns) = on-chain total_supply`.
5. **Collateralization** — bank reserves ≥ on-chain `total_supply`; a breach raises an alert.
6. **Auditability** — every privileged action is signed, logged, and replayable from the audit log.
7. **One door to the chain** — no service holds Solana RPC connections directly; all chain access is
   via `chain-bridge`.
8. **No server-side user keys** — no user wallet private key is ever held server-side.
9. **PII discipline** — PII is tagged at ingest, retention is enforced, and right-to-erasure cascades
   through all projections.

## 2. External Interfaces

Three segregated gateways, each with its own authn posture:

| Gateway | Callers | Auth | Hardening |
| :--- | :--- | :--- | :--- |
| `public-api` | Customer apps (trading PWA, portal) | HTTPS + JWT | Rate limited, per-user quotas |
| `partner-api` | Bank webhooks (SCB, KBank, TMB) | mTLS + IP allowlist | Signature verify, webhook normalize |
| `admin-api` | Ops, regulator (admin, BoT API) | SSO + MFA | Audit logged, 4-eyes principle |

## 3. Event Bus (Kafka)

All cross-service communication is event-sourced over Kafka.

- **Topics**: `mint.events`, `burn.events`, `compliance.events`, `treasury.events`, `reserve.events`,
  `chain.events`, `audit.security`, `alerts.reconciliation.discrepancy`, `governance.events`.
- **Schemas**: Avro, registered in a schema registry.
- **Retention**: 7-year retention on audit topics; tiered to S3 after 90 days.

## 4. Core Services

| Service | Responsibility |
| :--- | :--- |
| `mint-service` | Idempotent mint state machine |
| `burn-service` | Burn state machine + fiat payout queue |
| `compliance-service` | KYC, AML, sanctions screening, risk ML |
| `treasury-service` | Multi-bank balance + routing |
| `reserve-service` | Attestation oracle, publishes reserve proofs |
| `reconciliation-service` | Hourly + daily reconciliation, invariant checks |

## 5. Integration Adapter Layer

Isolates the core from external systems behind stable contracts:

- **bank-adapter** — router + per-bank drivers (SCB OAuth, KBank mTLS, TMB, …).
- **kyc-adapter** — NDID primary, Sumsub fallback, Onfido for non-Thai subjects.
- **chain-adapter** — `chain-bridge` gRPC client to GridChain.
- **multisig-coordinator** — Squads-style on-chain multisig orchestration.
- **reporting-adapter** — regulator APIs (BoT, SEC, AMLO).

## 6. On-Chain (GridChain · Anchor programs)

| Program | Role |
| :--- | :--- |
| gTHB Token | mint · burn · freeze · pause |
| Registry | KYC anchor, wallet binding |
| ValidatorSet | governance |
| Audit Log | append-only on-chain trail |

## 7. Storage & Security Planes

**Storage plane**
- Per-service Postgres (`mint_db`, `burn_db`, …) with logical replication to DR.
- Redis cluster — idempotency, session, rate limit, presence.
- Object storage (S3 + WORM) — audit log, attestations, encrypted KYC docs, 7-year retention.
- Time-series — metrics (Prometheus/Mimir), logs (Loki), traces (Tempo).

**Security plane**
- Vault Transit — DB creds, API keys, PII envelope encryption.
- Cloud HSM — attestation oracle key, master KEK.
- Multisig HSMs — 5 geographically separated mint/burn signing keys.
- SPIFFE/SPIRE — workload identity, automatic mTLS rotation.

## 8. Audit, Compliance & Observability

**Audit + compliance**
- Immutable audit log over every state transition and privileged action, chained cryptographically.
- Attestation cadence: reserve attestation every 5 min; Big-4 audit monthly; full audit quarterly.
- Reporting: monthly to BoT, quarterly transparency report, annual audited financials, SARs to AMLO
  within 24h, public dashboard.

**Observability + SLOs**
- Golden signals per service (rate, errors, latency, saturation).
- Domain dashboards: mint funnel, burn funnel, real-time reserve health, per-bank balance,
  reconciliation gap, compliance queue depth.

| SLO | Target |
| :--- | :--- |
| Public API uptime | 99.9% |
| Mint complete (p95) | < 5 min |
| Burn complete (p95) | < T+1 |
| Reserve attestation freshness | < 10 min |
| Reconciliation | 100% daily |

## 9. Deployment Topology

| Region | Role |
| :--- | :--- |
| Primary — Bangkok | Active; all services; treasury ops; bank API calls originate here |
| DR — Chiang Mai | Hot standby; Postgres logical replica; Kafka MirrorMaker; **RTO < 15 min · RPO < 5 min** |

Regions are joined by Kubernetes federation. Delivery is GitOps (Argo CD) with signed images
(cosign) and policy enforcement (Kyverno/OPA).

## 10. Phasing

| Phase | Window | Shape |
| :--- | :--- | :--- |
| 0 — PoC | 0–6 mo | 1 service · 1 bank · manual ops · 100% multisig · ~10/day |
| 1 — Sandbox | 6–18 mo | 3–4 services · 1 bank · partial automation · ~1K/day |
| 2 — Regional | 18–36 mo | Full decomposition · 2–3 banks · ~50K/day |
| 3 — National | 36+ mo | Multi-region · real-time attestation · multi-bank · ~500K/day |

---

See [`National.md`](National.md) for the broader national-scale deployment context and the
[glossary](../glossary.md) for domain terms.
