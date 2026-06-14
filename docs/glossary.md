# GridTokenX Glossary

> Domain-specific terms used across the GridTokenX platform.
> Last reviewed: 2026-04-16

---

## Energy & Grid Terms

| Term | Definition |
|:---|:---|
| **Prosumer** | An entity that both produces and consumes energy (e.g., a household with rooftop solar). |
| **DER** | Distributed Energy Resource — small-scale power generation or storage connected to the grid (solar panels, batteries, EV chargers). |
| **VPP** | Virtual Power Plant — an aggregation of multiple DERs managed as a single entity for grid services. |
| **P2P Energy Trading** | Peer-to-peer energy trading — direct energy transactions between prosumers and consumers without a central utility as intermediary. |
| **REC** | Renewable Energy Certificate — a tradeable proof that 1 MWh of electricity was generated from a renewable source. |
| **I-REC** | International REC — globally recognized standard for RECs. |
| **kWh** | Kilowatt-hour — unit of energy measurement. 1 kWh = 1,000 watts sustained for one hour. |
| **DR** | Demand Response — programs that adjust consumer energy usage in response to grid conditions. |
| **LOLE** | Loss of Load Expectation — a reliability metric measuring the expected number of hours when demand exceeds supply. |
| **NILM** | Non-Intrusive Load Monitoring — technique to disaggregate total household energy consumption into individual appliance usage without dedicated sub-meters. |
| **AMI** | Advanced Metering Infrastructure — integrated system of smart meters, communication networks, and data management systems. |
| **CT Clamp** | Current Transformer Clamp — a sensor that clips around a wire to measure current flow without breaking the circuit. |
| **TOU** | Time-of-Use — a tariff structure where electricity prices vary based on the time of day. |
| **Wheeling Charge** | Fee paid to a grid operator for transporting electricity through their network. |
| **WMA** | Weighted Moving Average — a recursive filtering technique (implemented as 80/20) used to smooth temporal jitter in smart meter telemetry. |
| **P_FiT** | Feed-in-Tariff — the base price per kWh (Default: 0.10 GRX) paid to prosumers for surplus energy exported to the grid. |
| **M_zone** | Incentive Multiplier — a zone-specific multiplier used to programmatically incentivize generation in specific geographic areas. |
| **Meritocratic Voting Weight** | A governance mechanism where voting power is derived from cumulative physical energy contribution ($\sum E$), not just token holdings. |
| **FT (Ft)** | Float Tariff — a variable component of Thailand's electricity tariff that reflects fuel and policy costs. |
| **Substation** | A facility that transforms voltage levels for electricity distribution. In GridTokenX, substation-level edge nodes aggregate meter data. |

---

## Blockchain & Token Terms

| Term | Definition |
|:---|:---|
| **GRID** | GridTokenX energy token — an SPL Token-2022 on Solana representing tokenized energy (1 GRID ≈ 1 kWh). |
| **GRX** | GridTokenX governance/utility token — used for platform governance, staking, and access control. |
| **gTHB** | Thai Baht stablecoin — a 1:1 reserve-backed digital representation of THB for on-chain settlement. |
| **PDA** | Program Derived Address — a deterministic Solana account address derived from seeds and a program ID. Used for user accounts and market state. |
| **ATA** | Associated Token Account — the canonical SPL token account for a given wallet and mint combination. |
| **SPL Token** | Solana Program Library Token — the standard token program on Solana. GridTokenX uses SPL Token-2022 (with extensions). |
| **SPL Token-2022** | The upgraded SPL token program with transfer hooks, interest-bearing tokens, and other extensions. |
| **Anchor** | Framework for building Solana programs (smart contracts) in Rust. GridTokenX uses Anchor 1.0.0. |
| **BPF/SBF** | Berkeley Packet Filter / Solana Binary Format — the bytecode format for Solana programs. |
| **Sealevel** | Solana's parallel transaction execution engine. Allows concurrent processing of non-conflicting transactions. |
| **CPI** | Cross-Program Invocation — one Solana program calling another program's instructions. |
| **Localnet** | A local Solana validator instance for development and testing. |
| **Devnet** | Solana's public development network for staging and integration testing. |
| **Mint** | The on-chain account that defines a token's properties (supply, decimals, authority). Also the action of creating new tokens. |
| **Burn** | Permanently destroying tokens by removing them from circulation. |
| **Freeze** | Temporarily locking a token account to prevent transfers (used for compliance). |

---

## Trading & Market Terms

| Term | Definition |
|:---|:---|
| **CDA** | Continuous Double Auction — the matching algorithm used by GridTokenX. Orders are continuously matched as they arrive, with price-time priority. |
| **Order Book** | A data structure that stores all outstanding buy and sell orders for a market, sorted by price. |
| **Bid** | A buy order — an offer to purchase energy at a specified price. |
| **Ask** | A sell order — an offer to sell energy at a specified price. |
| **Spread** | The difference between the best bid price and the best ask price. |
| **CQRS** | Command Query Responsibility Segregation — separating write operations from read-optimized queries. A planned pattern; ClickHouse was the intended OLAP read side but is **not currently provisioned** (see ClickHouse below). |
| **DCA** | Dollar-Cost Averaging — a strategy of placing recurring orders at fixed intervals. |
| **Stop-Loss** | An order that triggers a market sell when the price drops below a threshold. |
| **Take-Profit** | An order that triggers a market sell when the price rises above a threshold. |
| **Settlement** | The process of finalizing a trade by transferring tokens on-chain (energy tokens + payment tokens). |

---

## Platform & Infrastructure Terms

| Term | Definition |
|:---|:---|
| **ConnectRPC** | A gRPC-compatible protocol that works over HTTP/1.1 and HTTP/2, with browser support. Used for inter-service communication. |
| **mTLS** | Mutual TLS — both client and server present certificates for authentication. Used for IoT device connections via Envoy. |
| **SPIFFE** | Secure Production Identity Framework for Everyone — provides cryptographic identities (SVIDs) to workloads. Format: `spiffe://gridtokenx.th/prod/<service>`. |
| **SPIRE** | SPIFFE Runtime Environment — the server/agent pair that issues and manages SPIFFE identities. |
| **Vault Transit** | HashiCorp Vault's encryption-as-a-service backend. Chain Bridge uses it for transaction signing without exposing private keys. |
| **NATS JetStream** | Distributed messaging system with persistence. Used by Chain Bridge for async transaction submission (`chain.tx.submit`). |
| **OrbStack** | Lightweight Docker runtime for macOS — replaces Docker Desktop with 2-second startup and lower resource usage. |
| **APISIX** | Apache APISIX — the user-facing API gateway (port 4001). Handles JWT validation, rate limiting, CORS, WebSocket proxying. |
| **Envoy** | Edge proxy for IoT devices (port 4002). Enforces mTLS, device certificates, and payload size limits. |
| **Kafka** | Distributed event streaming platform. GridTokenX uses 3 logical clusters: cmd-events (9001), market-data (9002), audit (9003). |
| **RabbitMQ** | Message broker for task queues. Used for email notifications, settlement retries, and dead letter queues (DLQ). |
| **ClickHouse** | Column-oriented OLAP database. Intended as the CQRS read side for analytics. **Not currently provisioned** — no ClickHouse container in the stack and no client in any service. Listed for design context and to disambiguate older docs. |
| **InfluxDB** | Time-series database. **Not used and not provisioned** — there is no InfluxDB container in the stack and no client in any service. Verified meter telemetry is disseminated to zone-partitioned Redis Streams + Kafka. Listed only to disambiguate older docs that referenced it. |
| **SQLx** | Rust SQL toolkit with compile-time query verification. Primary ORM for Postgres. |

---

## Regulatory & Compliance Terms

| Term | Definition |
|:---|:---|
| **PDPA** | Personal Data Protection Act — Thailand's data privacy law (similar to GDPR). Governs how GridTokenX handles user PII. |
| **ERC** | Energy Regulatory Commission — Thai regulator overseeing electricity markets. GridTokenX operates under ERC sandbox terms. |
| **Thai SEC** | Securities and Exchange Commission of Thailand — regulates digital assets and tokens. |
| **KYC** | Know Your Customer — identity verification required before a user can trade. |
| **AML** | Anti-Money Laundering — compliance checks on transaction patterns. |
| **AMLO** | Anti-Money Laundering Office — Thai regulatory body for AML enforcement. |
| **BoT** | Bank of Thailand — central bank, relevant for gTHB stablecoin reserve attestation. |
| **NDID** | National Digital ID — Thailand's federated identity verification platform. |
| **PEA** | Provincial Electricity Authority — operates the distribution grid outside Bangkok. |
| **MEA** | Metropolitan Electricity Authority — operates the distribution grid within Bangkok. |
| **EGAT** | Electricity Generating Authority of Thailand — national power generation utility. |

---

## Architecture Abbreviations

| Abbreviation | Full Form |
|:---|:---|
| **DI** | Dependency Injection |
| **DDD** | Domain-Driven Design |
| **DLQ** | Dead Letter Queue |
| **HA** | High Availability |
| **RTO** | Recovery Time Objective |
| **RPO** | Recovery Point Objective |
| **SLO** | Service Level Objective |
| **OTEL** | OpenTelemetry |
| **ADR** | Architecture Decision Record |
