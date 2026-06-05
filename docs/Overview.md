# GridTokenX Documentation Overview

This file outlines the documentation structure for the GridTokenX core system.

## Project Structure

The project is structured as a collection of microservices and shared libraries, primarily written in Rust, Python, and TypeScript.

```
gridtokenx-coresystem/
├── README.md                      # Main entry point and project description
├── SECURITY.md                    # Security policies
├── CONTRIBUTING.md                # Contribution guidelines
├── CLAUDE.md                      # General LLM coding conventions
├── docker-compose.yml             # Local development infrastructure definition
├── docs/                          # Project-wide documentation
│   ├── Overview.md                # This file
│   ├── MINTING_E2E_FLOW.md        # End-to-end flow for token minting
│   ├── National.md                # System architecture and deployment tiers
│   └── ...                        # Other academic and architectural docs
├── gridtokenx-iam-service/        # Identity and Access Management service (Rust)
├── gridtokenx-trading-service/    # Core trading and settlement engine (Rust)
├── gridtokenx-noti-service/       # Notification delivery service (Rust)
├── gridtokenx-oracle-bridge/      # IoT gateway and telemetry ingestion (Rust)
├── gridtokenx-blockchain-core/    # Shared Solana/Anchor blockchain library (Rust)
├── gridtokenx-chain-bridge/       # Vault-backed Solana transaction bridge (Rust)
├── gridtokenx-smartmeter-simulator/ # Telemetry generation and testing (Python)
├── gridtokenx-trading/            # Web frontend for the trading platform (Next.js)
├── gridtokenx-explorer/           # Blockchain explorer interface (Next.js)
└── gridtokenx-anchor/             # Solana Anchor smart contracts
```

## Documentation Strategy

Documentation is decentralized where possible. Service-specific documentation lives within the respective service directories (e.g., `gridtokenx-chain-bridge/README.md`, `gridtokenx-iam-service/ARCHITECTURE.md`).

Cross-cutting concerns and high-level architectural overviews are located in the `docs/` folder.

- **Service Level**: Use `README.md` and `ARCHITECTURE.md` within the service folder to explain the service's responsibilities, internal architecture, and how to run it.
- **System Level**: Use `docs/` for end-to-end flows (`MINTING_E2E_FLOW.md`) and deployment architecture (`National.md`).
- **Blockchain Level**: Use `gridtokenx-anchor/docs/` or `gridtokenx-blockchain-core/` for detailed smart contract specifications.
