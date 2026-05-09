# Solana Mainnet Simulation with Surfpool

This project uses [Surfpool](https://surfpool.run) for realistic mainnet simulation and integration testing. Surfpool provides an instant-start local network with lazy mainnet state cloning.

## Quick Start

### Start Mainnet Simulation
To start a local Solana network forking mainnet state:

```bash
just simnet
```

This will:
- Fork Mainnet state lazily (accounts are fetched from mainnet on first access).
- Enable Surfpool Studio (Web UI) at [http://localhost:18488](http://localhost:18488).
- Start instruction-level profiling and hot-reloading for programs.

### Stop Simulation
```bash
just simnet-down
```

## Running Tests against Simnet

### Anchor Tests
Point your Anchor tests to the Simnet by ensuring `Anchor.toml` uses `cluster = "localnet"` (default for Simnet) and run:

```bash
cd gridtokenx-anchor
pnpm simnet
```

In another terminal, run your tests:
```bash
anchor test --skip-local-validator
```

### Integration Scripts
Scripts like `test-onchain-verification.sh` will automatically use the Simnet if it's running on port 8899.

```bash
./scripts/test-onchain-verification.sh
```

## Advanced Usage

### CI Mode
For headless environments or CI pipelines, use the CI mode which disables the TUI and Studio:

```bash
just simnet-ci
```

### Mainnet Account Cloning
You don't need to manually clone accounts. Surfpool fetches them on-demand. For example, if your program interacts with the Jupiter aggregator or Pyth oracles on mainnet, their state will be automatically available in your local simulation.

### Cheatcodes
Surfpool supports 22 `surfnet_*` RPC methods to manipulate time and account state at runtime. See the [Surfpool documentation](https://docs.surfpool.run) for more details.
