---
description: Working with Anchor smart contracts
---

# Anchor Smart Contracts

Develop, test, and deploy Solana smart contracts using Anchor.

## Quick Commands

// turbo

```bash
cd gridtokenx-anchor

# Build programs
anchor build

# Run tests
anchor test

# Deploy to localnet
anchor deploy

# Run with local validator
anchor run
```

## Project Structure

```
gridtokenx-anchor/
├── programs/
│   ├── registry/          # Registry program
│   ├── energy_token/      # Token program
│   ├── trading/           # Trading program
│   ├── oracle/            # Oracle program
│   └── governance/        # Governance program
├── tests/                 # TypeScript tests
├── migrations/            # Deploy scripts
├── scripts/               # Utility scripts
└── Anchor.toml            # Anchor configuration
```

## Development Workflow

### 1. Initialize Project

```bash
# Already initialized in gridtokenx-anchor
cd gridtokenx-anchor
```

### 2. Create New Program

```bash
anchor init <program-name> --javascript
```

Or manually create program structure:

```rust
// programs/registry/src/lib.rs
use anchor_lang::prelude::*;

declare_id!("FmvDiFUWsqo7z7XnVniKbZDcz32U5HSDVwPug89c");

#[program]
pub mod registry {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
        // Initialization logic
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,
}
```

### 3. Build Program

```bash
cd gridtokenx-anchor

# Build all programs
anchor build

# Build specific program
cargo build-bpf --manifest-path programs/registry/Cargo.toml
```

### 4. Test Program

```bash
# Run all tests
anchor test

# Run with skip build
anchor test --skip-build

# Run specific test file
anchor test tests/registry.ts
```

### 5. Deploy Program

```bash
# Deploy to localnet
anchor deploy --provider.cluster localnet

# Deploy to devnet
anchor deploy --provider.cluster devnet

# Deploy to mainnet-beta
anchor deploy --provider.cluster mainnet-beta
```

## Program IDs

Programs use fixed keypairs for consistent IDs:

| Program | Program ID |
|---------|------------|
| Registry | `FmvDiFUWsqo7z7XnVniKbZDcz32U5HSDVwPug89c` |
| Energy Token | `n52aKuZwUeZAocpWqRZAJR4xFhQqAvaRE7Xepy2JBGk` |
| Trading | `69dGpKu9a8EZiZ7orgfTH6CoGj9DeQHHkHBF2exSr8na` |
| Oracle | `JDUVXMkeGi4oxLp8njBaGScAFaVBBg7iGoiqcY1LxKop` |
| Governance | `DamT9e1VqbA5nSyFZHExKwQu6qs4L5FW6dirWCK8YLd4` |

## Testing

### TypeScript Tests

```typescript
// tests/registry.ts
import * as anchor from "@coral-xyz/anchor";
import { assert } from "chai";

describe("registry", () => {
  const provider = anchor.AnchorProvider.env();
  const program = anchor.workspace.Registry;

  it("Initializes successfully", async () => {
    const [registryPda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("registry")],
      program.programId
    );

    await program.methods
      .initialize()
      .accounts({
        registry: registryPda,
        signer: provider.publicKey,
      })
      .rpc();

    const registry = await program.account.registry.fetch(registryPda);
    assert.ok(registry.authority.equals(provider.publicKey));
  });
});
```

### Running Tests

```bash
# Start local validator
solana-test-validator --reset --limit-ledger-size 10000

# Run tests
anchor test

# Run with coverage
anchor test --coverage
```

## Account Management

### Fetch Account Data

```bash
# Fetch account by address
anchor account <ACCOUNT_ADDRESS>

# Fetch account with program ID
anchor account <ACCOUNT_ADDRESS> --program-id <PROGRAM_ID>
```

### List Program Accounts

```bash
solana program-accounts <PROGRAM_ID> --output json
```

## IDL (Interface Description Language)

### Generate IDL

```bash
# Generate IDL during build
anchor build

# IDL files are in:
# target/idl/<program-name>.json
# target/types/<program-name>.ts
```

### Use IDL in Frontend

```typescript
import { Program, AnchorProvider } from "@coral-xyz/anchor";
import { RegistryIDL } from "./target/types/registry";

const provider = AnchorProvider.env();
const program = new Program<RegistryIDL>(IDL, provider);
```

## Common Patterns

### PDA (Program Derived Address)

```rust
#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = signer,
        seeds = [b"registry"],
        bump,
    )]
    pub registry: Account<'info, RegistryData>,
    #[account(mut)]
    pub signer: Signer<'info>,
    pub system_program: Program<'info, System>,
}
```

### Cross-Program Invocation (CPI)

```rust
#[account]
pub struct TradingMarket {
    pub market_authority: Pubkey,
    pub fee_collector: Pubkey,
}

#[derive(Accounts)]
pub struct ExecuteTrade<'info> {
    #[account(mut)]
    pub user: Signer<'info>,
    #[account(
        seeds = [b"market"],
        bump,
    )]
    pub market: Account<'info, TradingMarket>,
    pub token_program: Program<'info, Token>,
}
```

### Events

```rust
#[event]
pub struct OrderCreated {
    pub order_id: u64,
    pub user: Pubkey,
    pub energy_amount: u64,
    pub price: u64,
}

// Emit event
emit!(OrderCreated {
    order_id: 1,
    user: *user.key,
    energy_amount: 1000,
    price: 150,
});
```

## Debugging

### Enable Debug Logging

```rust
// In program code
msg!("Debug: User = {}", user.key);
msg!("Debug: Amount = {}", amount);
```

### View Program Logs

```bash
# During tests
anchor test -- --nocapture

# On validator
solana logs --url http://localhost:8899
```

### Simulate Transaction

```typescript
const result = await program.methods
  .initialize()
  .accounts({ ... })
  .simulate();

console.log(result.logs);
```

## Deployment Scripts

### Bootstrap Script

```typescript
// scripts/bootstrap.ts
import * as anchor from "@coral-xyz/anchor";

async function bootstrap() {
  const provider = anchor.AnchorProvider.env();
  const program = anchor.workspace.Registry;

  // Initialize registry
  const [registryPda] = anchor.web3.PublicKey.findProgramAddressSync(
    [Buffer.from("registry")],
    program.programId
  );

  await program.methods
    .initialize()
    .accounts({
      registry: registryPda,
      signer: provider.publicKey,
    })
    .rpc();

  console.log("Registry initialized at:", registryPda.toString());
}

bootstrap();
```

### Run Bootstrap

```bash
cd gridtokenx-anchor
export ANCHOR_PROVIDER_URL=http://localhost:8899
export ANCHOR_WALLET=target/deploy/registry-keypair.json

npx ts-node scripts/bootstrap.ts
```

## Related Workflows

- [Blockchain Init](./blockchain-init.md) - Deploy programs
- [Testing](./testing.md) - Run tests
- [Build & Deploy](./build-deploy.md) - Build and deployment
