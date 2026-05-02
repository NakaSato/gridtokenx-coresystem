GRIDTOKENX FULL SYSTEM ARCHITECTURE
====================================================================================

[ TIER 0: NATIONAL CONTROL PLANE ] (Bangkok Primary + DR)
---------------------------------------------------------
|  - Federated IAM (Master KYC & Identity)
|  - National REC Registry (Master Truth for Energy Credits)
|  - Cross-Region Settlement Coordinator
|  - Regulatory Gateways (ERC, Thai SEC, EGAT, NESDB)
|  - Solana L1 Anchoring (State root checkpoints)
---------------------------------------------------------
      |
      +-------+---------------+---------------+---------------+---------------+
              |               |               |               |               |
              v               v               v               v               v
[ TIER 1: REGIONAL CLUSTERS ] (PEA-N, PEA-NE, PEA-C, PEA-S, MEA)
------------------------------------------------------------------------------------
|  - Execution Plane: Order matching, Settlement, Risk, VPP dispatch
|  - Chain Plane: Regional SVM Rollup (App-chain), Chain Bridge
|  - Messaging: Triple-Kafka stack (Command, Market, Audit)
|  - Persistence: CQRS (Postgres/Redis) + Analytics (ClickHouse/Influx)
------------------------------------------------------------------------------------
      | (Command Dispatch / Telemetry Stream)
      v
[ TIER 2: EDGE / PROVINCE AGGREGATORS ] (74 Province DCs)
---------------------------------------------------------
|  - Regional Edge: WAF, NLB, Envoy (mTLS termination)
|  - Ingestion: Protocol translation (MQTT/CoAP -> Kafka)
|  - Local buffering & Ed25519 device authentication
---------------------------------------------------------
      |
      v
[ TIER 3: SUBSTATION NODES ] (~5,000 Edge Nodes)
---------------------------------------------------------
|  - Local DR firing (sub-second response)
|  - Data pre-validation & 60s buffering
|  - Protocol: Edge-to-Oracle Bridge (Signed payloads)
---------------------------------------------------------
      |
      v
[ TIER 4: METER / IOT TIER ] (Millions of Devices)
---------------------------------------------------------
|  - Hardware: AMI, Inverters, EVSE, Home Batteries
|  - Security: Ed25519 signing on-chip (gridtokenx-edge-meter)
|  - Logic: Smart Meter Simulator / Real hardware
---------------------------------------------------------


NATIONAL CONTROL PLANE  (Bangkok primary + DR site)
+------------------------------------------------------------------------------------+
|                                                                                    |
|  [Federated IAM]    [National REC      [Cross-region       [Regulatory gateway]    |
|   identity, KYC      registry           settlement          ERC · Thai SEC ·       |
|   wallet anchor]     (master truth)     coordinator]        EGAT · NESDB           |
|                                                                                    |
|  [Schema registry]  [KMS / HSM]        [Observability      [Solana L1 anchoring]   |
|   contract specs     national keys      Mimir/Loki/Tempo    state roots,           |
|   evolution gates    Vault + cloudHSM   SLO + budgets       hourly checkpoints]    |
|                                                                                    |
+-----+----------------+----------------+----------------+----------------+----------+
      |                |                |                |                |
      v                v                v                v                v
  +-------+        +-------+        +-------+        +-------+        +-------+
  | NORTH |        | N-EAST|        |CENTRAL|        | SOUTH |        | METRO |
  | PEA-N |        | PEA-NE|        | PEA-C |        | PEA-S |        | (MEA) |
  +---+---+        +---+---+        +---+---+        +---+---+        +---+---+
      |                |                |                |                |
      | full regional stack per region (Diagram 2)                        |
      v                v                v                v                v
  +------------------------------------------------------------------------+
  |       EDGE / PROVINCE TIER  (74 province aggregators)                  |
  +------------------------------------------------------------------------+
                                  |
                                  v
  +------------------------------------------------------------------------+
  |       SUBSTATION TIER  (~5,000 substation edge nodes)                  |
  |       local DR firing · pre-validation · 60s buffering                 |
  +------------------------------------------------------------------------+
                                  |
                                  v
  +------------------------------------------------------------------------+
  |       METER TIER  (millions of devices)                                |
  |       AMI · rooftop inverters · EVSE · battery controllers             |
  +------------------------------------------------------------------------+


REGION  (e.g. PEA-North, runs in Chiang Mai datacenter + Bangkok DR)
+----------------------------------------------------------------------------+
|  CLIENTS                                                                   |
|  [Trading PWA]  [Portal]  [Explorer]  [Mobile]  [DSO ops console]          |
|       |            |          |          |             |                   |
|       v            v          v          v             v                   |
|  +---------------------------------------------------------+               |
|  | Regional edge: WAF -> NLB -> Kong (3+ replicas)         |               |
|  +---------------------------+-----------------------------+               |
|                              v                                             |
|  +---------------------------+-----------------------------+               |
|  | API tier: gridtokenx-api (Axum, N pods, stateless)      |<--> Redis     |
|  | thin BFF + WS hub + command publisher                   |     cluster   |
|  +---------------------------+-----------------------------+               |
|                              v                                             |
|  +========================== SERVICE MESH (Istio + mTLS) ===============+  |
|                              v                                             |
|     +-----------+-----------+-----------+-----------+-----------+          |
|     v           v           v           v           v           v          |
|  [IAM]    [Order book]  [Matching   [Settlement] [Risk]   [DR / VPP        |
|           write/read     engine                  engine]  dispatcher]      |
|           CQRS split]    in-memory                                         |
|     |          |   |         |           |          |          |           |
|     |          |   +- write  +-event-+   |          |          |           |
|     |          |              hot path                                     |
|     v          v                          v          v          v          |
|  +------------------------------------------------------------------+      |
|  | THREE Kafka clusters by traffic class (NOT one):                 |      |
|  |  - cmd-events     (durable, ordered, small)                      |      |
|  |  - market-data    (high-TPS, ephemeral, large)                   |      |
|  |  - audit          (regulatory, tiered S3, 7yr retention)         |      |
|  +------------------------------------------------------------------+      |
|                                                                            |
|  CQRS READ SIDE  (consumes from Kafka, never blocks writes)                |
|  [order projection]  [trade history]  [position service]  [analytics]      |
|   Redis + Postgres    ClickHouse       Postgres            ClickHouse      |
|                                                                            |
|  TELEMETRY PIPELINE  (independent of trading, scales separately)           |
|  [ingest]  ->  [NILM/validation]  ->  [forecasting CTT-ViT]                |
|     |                  |                       |                           |
|     v                  v                       v                           |
|  TimescaleDB hot   ClickHouse warm        Object store cold (S3)           |
|                                                                            |
|  CHAIN TIER                                                                |
|  [Regional Solana app-chain / SVM rollup]  --hourly state root-->  L1      |
|  Validator set: PEA + MEA + EGAT + 2 universities + 2 independent          |
+----------------------------------------------------------------------------+
                              ^
                              | telemetry stream from edge tier
