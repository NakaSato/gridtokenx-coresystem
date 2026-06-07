==================================================================================================
   gTHB ISSUER SERVICE  ·  large-scale architecture
==================================================================================================


   EXTERNAL ACTORS
+----------------------+   +----------------------+   +----------------------+
|  customer apps       |   |  bank webhooks       |   |  ops · regulator     |
|  trading PWA, portal |   |  SCB · KBank · TMB   |   |  admin · BoT API     |
+----------+-----------+   +----------+-----------+   +----------+-----------+
           |                          |                          |
           | HTTPS + JWT              | mTLS + IP allowlist      | SSO + MFA
           v                          v                          v
+----------------------+   +----------------------+   +----------------------+
|  public-api          |   |  partner-api         |   |  admin-api           |
|  rate limited        |   |  signature verify    |   |  audit logged        |
|  per-user quotas     |   |  webhook normalize   |   |  4-eyes principle    |
+----------+-----------+   +----------+-----------+   +----------+-----------+
           |                          |                          |
           v                          v                          v

+================================================================================================+
|                                  KAFKA EVENT BUS                                               |
|                                                                                                |
|  mint.events  · burn.events  · compliance.events  · treasury.events  · reserve.events          |
|  chain.events · audit.security · alerts.reconciliation.discrepancy · governance.events         |
|                                                                                                |
|  schemas: Avro registered · 7yr retention (audit) · S3 tiered after 90d                        |
+----+----------+----------+----------+----------+-----------+-----------+-----------------------+
     |          |          |          |          |           |           |
     v          v          v          v          v           v           v

+----------+ +----------+ +----------+ +----------+ +----------+ +-----------+
| mint-    | | burn-    | |compliance| | treasury | | reserve  | | recon-    |
| service  | | service  | | service  | | service  | | service  | | ciliation |
|          | |          | |          | |          | |          | | service   |
| state    | | state    | | KYC,AML, | | multi-   | | attest.  | | hourly +  |
| machine, | | machine, | | sanctions| | bank     | | oracle,  | | daily +   |
| idempot- | | payout   | | screen,  | | balance, | | publish  | | invariant |
| ent      | | queue    | | risk ML  | | routing  | | proofs   | | check     |
+----+-----+ +----+-----+ +----+-----+ +----+-----+ +----+-----+ +----+------+
     |            |            |            |            |            |
     v            v            v            v            v            v

+================================================================================================+
|                          INTEGRATION ADAPTER LAYER                                             |
|                                                                                                |
|  bank-adapter (router + per-bank: SCB OAuth, KBank mTLS, TMB ...)                              |
|  kyc-adapter  (NDID primary, Sumsub fallback, Onfido for non-Thai)                             |
|  chain-adapter (chain-bridge gRPC client to GridChain)                                         |
|  multisig-coordinator (Squads-style on-chain multisig orchestration)                           |
|  reporting-adapter (BoT, SEC, AMLO regulator APIs)                                             |
|                                                                                                |
+----+----------------+-----------------+----------------+----------------+----------------------+
     |                |                 |                |                |
     v                v                 v                v                v

+----------+   +----------------+   +----------------+   +----------+   +-----------+
| Thai     |   | NDID · Sumsub  |   | Squads multi-  |   | chain-   |   | regulator |
| banks    |   | Onfido         |   | sig signers    |   | bridge   |   | endpoints |
| SCB·KBank|   | KYC providers  |   | (5 distributed)|   | service  |   | (BoT/SEC) |
+----------+   +----------------+   +----------------+   +----+-----+   +-----------+
                                                              |
                                                              v
+================================================================================================+
|                ON-CHAIN  ·  GridChain  ·  Anchor programs                                      |
|                                                                                                |
|  +---------------+ +---------------+ +---------------+ +---------------+                       |
|  | gTHB Token    | | Registry      | | ValidatorSet  | | Audit Log     |                       |
|  | mint · burn   | | KYC anchor    | | governance    | | append-only   |                       |
|  | freeze · pause| | wallet binding| |               | |               |                       |
|  +---------------+ +---------------+ +---------------+ +---------------+                       |
+================================================================================================+


   STORAGE PLANE                                          SECURITY PLANE
+--------------------------------+               +--------------------------------+
| per-service Postgres           |               | Vault Transit                  |
|   mint_db · burn_db · etc      |               |   db creds · API keys          |
|   logical replication to DR    |               |   PII envelope encryption      |
|                                |               |                                |
| Redis cluster                  |               | Cloud HSM                      |
|   idempotency · session        |               |   attestation oracle key       |
|   rate limit · presence        |               |   master KEK                   |
|                                |               |                                |
| Object storage (S3 + WORM)     |               | Multisig HSMs (5 distributed)  |
|   audit log · attestations     |               |   mint/burn signing keys       |
|   KYC docs (encrypted)         |               |   geographically separated     |
|   7yr regulatory retention     |               |                                |
|                                |               | SPIFFE/SPIRE                   |
| Time-series                    |               |   workload identity            |
|   metrics (Prometheus/Mimir)   |               |   automatic mTLS rotation      |
|   logs (Loki)                  |               |                                |
|   traces (Tempo)               |               |                                |
+--------------------------------+               +--------------------------------+


   AUDIT + COMPLIANCE                              OBSERVABILITY + SLOs
+--------------------------------+               +--------------------------------+
| immutable audit log            |               | golden signals per service     |
|   every state transition       |               |   rate · errors · latency · sat|
|   every privileged action      |               |                                |
|   cryptographic chain          |               | domain dashboards              |
|                                |               |   mint funnel · burn funnel    |
| attestation cadence            |               |   reserve health (real-time)   |
|   reserve attestation: 5min    |               |   per-bank balance             |
|   Big 4 audit: monthly         |               |   reconciliation gap           |
|   full audit: quarterly        |               |   compliance queue depth       |
|                                |               |                                |
| reporting                      |               | SLOs                           |
|   monthly to BoT               |               |   public API uptime  99.9%     |
|   quarterly transparency       |               |   mint complete p95 < 5min     |
|   annual audited financials    |               |   burn complete p95 < T+1      |
|   SARs to AMLO < 24h           |               |   reserve attest fresh < 10min |
|   public dashboard             |               |   reconciliation 100% daily    |
+--------------------------------+               +--------------------------------+


==================================================================================================
   DEPLOYMENT TOPOLOGY
==================================================================================================

   PRIMARY REGION (Bangkok)            DR REGION (Chiang Mai)
+----------------------------+      +----------------------------+
|  active                    |      |  hot standby               |
|  all services running      |      |  Postgres logical replica  |
|  treasury operations here  |      |  Kafka MirrorMaker         |
|  bank API calls from here  |      |  RTO < 15min · RPO < 5min  |
+-------------+--------------+      +-------------+--------------+
              |                                   |
              +-------- Kubernetes federation ----+
                              |
                         GitOps (Argo CD)
                         signed images (cosign)
                         policy enforcement (Kyverno/OPA)


==================================================================================================
   PHASING (within Issuer Service)
==================================================================================================

  Phase 0  (PoC, 0-6mo)       1 service · 1 bank · manual ops · 100% multisig · ~10/day
  Phase 1  (sandbox, 6-18mo)  3-4 services · 1 bank · partial automation · ~1K/day
  Phase 2  (regional, 18-36)  full decomposition · 2-3 banks · ~50K/day
  Phase 3  (national, 36+)    multi-region · real-time attestation · ~500K/day · multi-bank


==================================================================================================
   ARCHITECTURAL INVARIANTS  (these never bend)
==================================================================================================

  - mint completes only if THB received AND KYC passed AND multisig approved AND on-chain success
  - burn completes only if on-chain burn confirmed BEFORE THB wire is queued
  - on-chain total_supply <= last attested reserves at all times
  - sum(confirmed mints) - sum(confirmed burns) = on-chain total_supply (accounting identity)
  - bank reserves >= on-chain total_supply (collateralization, alert if breached)
  - every privileged action is signed, logged, and replayable from audit log
  - no service holds Solana RPC connections directly (always via chain-bridge)
  - no user wallet private key is ever held server-side
  - PII tagged at ingest, retention policy enforced, right-to-erasure cascades through projections