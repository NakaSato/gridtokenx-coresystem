---
name: gridtokenx-global
description: Global workspace instructions and machine-specific configurations for GridTokenX.
---

# Global Workspace Skills & Config

Machine-specific configuration for the GridTokenX superproject. Scripts and manual commands must respect these constraints.

## Dev Machine: Apple Silicon (M2, 16 GB RAM)

### Solana Test Validator — "Too many open files"

`solana-test-validator` crashes under load on macOS Apple Silicon because default file-descriptor limits are tiny (256–2560).

- **Fix:** `ulimit -n 65536` before starting the validator. Already integrated into `scripts/cmd/start.sh` and `scripts/cmd/init.sh` — only needed manually when launching the validator outside those scripts.
- **Memory:** always pass `--limit-ledger-size 10000` so the ledger can't exhaust the 16 GB unified memory.

### Metaplex Localnet Programs

GridTokenX relies on Metaplex standards. The local test validator loads the Metaplex mainnet programs (`mpl-token-metadata`, `mpl-bubblegum`, `mpl-core`) at startup via `--bpf-program`, using the automated `scripts/setup-metaplex.sh` cache — no manual download.
