---
name: gridtokenx-global
description: Global workspace instructions and machine-specific configurations for GridTokenX.
---

# Global Workspace Skills & Config

This file contains global instructions and machine-specific configurations for the GridTokenX monorepo.

## Machine-Specific Configurations (Apple Silicon / M-Series)

This project is being developed on an Apple M2 machine with 16GB of RAM. The following optimizations must be respected by scripts and manual commands:

### Solana Test Validator (Too Many Open Files)
Running `solana-test-validator` natively on macOS (Apple Silicon) will crash under load due to aggressive default OS file descriptor limits (typically 256 or 2560). 
- **Fix:** Always tune the system limit by running `ulimit -n 65536` before starting the validator. This has been integrated into `scripts/cmd/start.sh` and `scripts/cmd/init.sh`.
- **Memory Limit:** Always use `--limit-ledger-size 10000` to prevent the ledger from exhausting the 16GB of unified memory.

### Metaplex Localnet Programs
GridTokenX relies heavily on Metaplex standards. The local test validator dynamically loads the Metaplex mainnet programs (`mpl-token-metadata`, `mpl-bubblegum`, `mpl-core`) on startup via the `--bpf-program` argument, using the automated `scripts/setup-metaplex.sh` cache.
