# Energy Token (GRX): On-Chain Structure & Logic

This document describes the design of the **Energy Token (GRX)** on the Solana blockchain, focusing on the SPL Token-2022 implementation, REC validation, and Sealevel optimization.

## Token Account Architecture

```mermaid
graph TD
    subgraph "GridTokenX Energy Token Program"
        TokenInfo[TokenInfo Account<br/>(PDA: 'token_info_2022')]
        Mint[SPL Mint Account<br/>(PDA: 'mint_2022')]
        Metadata[Metaplex Metadata<br/>(PDA: Metadata Program)]
    end

    subgraph "State Variables (TokenInfo)"
        Authority[Admin Authority]
        RegAuth[Registry Authority]
        Supply[Total Supply Cache]
        Validators[REC Validators (Max 5)]
    end

    TokenInfo -. "Mint Authority" .-> Mint
    Mint --- Metadata
    
    subgraph "User Wallets"
        ProsumerATA[Prosumer ATA<br/>(SPL-2022)]
        ConsumerATA[Consumer ATA<br/>(SPL-2022)]
    end

    Mint -- "MintTo" --> ProsumerATA
    ProsumerATA -- "Transfer / Burn" --> ConsumerATA
```

## Key Technical Features

### 1. SPL Token-2022 Standard
The platform uses the **SPL Token-2022** interface. This provides advanced extensions (like permanent delegates or interest-bearing fields) while maintaining backward compatibility with the original token program through the `token-interface` crate.

### 2. Renewable Energy Certificate (REC) Validation
To ensure that minted tokens represent genuine renewable energy, the program supports **REC Validators**.
*   **Constraint**: If validators are registered in `TokenInfo`, the `mint_tokens_direct` instruction **requires a co-signature** from one of the authorized validators.
*   **Significance**: This prevents the platform from minting tokens without independent verification of the energy provenance.

### 3. Sealevel Parallelism Optimization
In a high-throughput energy market, hundreds of meters may trigger minting events simultaneously. To avoid a bottleneck:
*   **The Problem**: Updating a single `total_supply` counter in an account on every transaction creates a "write-lock" that forces transactions to execute sequentially.
*   **The Solution**: The `mint_tokens_direct` instruction is **read-only** regarding the `TokenInfo` account. It uses the `TokenInfo` PDA as the mint authority but **does not update the supply counter** inside the `TokenInfo` state.
*   **Syncing**: An admin periodically calls `sync_total_supply`, which reads the supply from the canonical SPL Mint account (maintained by the SPL program) and updates the local cache in `TokenInfo`.

## Minting Constraints

| Instruction | Caller Permission | Requirements |
| :--- | :--- | :--- |
| `mint_to_wallet` | Admin Only | Administrative manual mint. |
| `mint_tokens_direct` | Admin OR Registry Program | Requires REC Validator co-signature if validators exist. |
| `burn_tokens` | Token Owner | Proof of energy consumption. |

## Metadata (Metaplex)
The token incorporates Metaplex Metadata to provide a human-readable identity in wallets and explorers:
*   **Name**: GridTokenX Energy
*   **Symbol**: GRX
*   **Decimals**: 9
*   **Standard**: Fungible
