# Solana Validator Performance Tuning (Firedancer)

This document outlines the requirements and configuration for running Firedancer/Frankendancer as the primary validator for GridTokenX to achieve high-throughput, low-latency energy trading.

## Performance Characteristics

| Metric | Target (Firedancer) | standard Agave (Rust) |
|--------|---------------------|-----------------------|
| Networking | Kernel Bypass (QUIC/UDP) | OS Kernel Stack |
| Cryptography | AVX512 Optimized | Standard Rust/Ed25519 |
| Scaling | 100k+ TPS (Network Limit) | 10k-50k TPS (typical) |
| Latency | Microsecond-scale jitter | Millisecond-scale jitter |

## Hardware Requirements

To leverage Firedancer's full performance, the following hardware is required:

- **CPU**: Modern x86_64 with **AVX512** support (Intel Ice Lake/Sapphire Rapids or AMD Zen 4+).
- **Network**: NICs compatible with kernel bypass (DPDK/custom bypass drivers). 25Gbps+ recommended.
- **Memory**: 512GB+ RAM with Hugepages enabled.
- **Storage**: NVMe Gen4/Gen5 for ledger data.

## OS Tuning (Linux)

### 1. Hugepages
Enable hugepages to reduce TLB misses during high-speed transaction processing.
```bash
echo 2048 | sudo tee /proc/sys/vm/nr_hugepages
```

### 2. CPU Pinning
Isolate Firedancer threads to specific physical cores to eliminate context switching jitter.

### 3. Kernel Bypass
Ensure `ethtool` and network drivers are configured for maximum ring buffer sizes and zero-copy if possible.

## Deployment: Frankendancer

GridTokenX utilizes **Frankendancer** (v0.1+) in production to bridge the high-speed Firedancer networking layer with the established Solana Agave runtime.

- **Status**: Beta.
- **Role**: Entry point for all incoming P2P energy transactions.
- **Benefit**: Native DoS resilience and high-burst capacity for energy market volatility.

## Chain Bridge Optimization

The `gridtokenx-chain-bridge` should be configured to target the Frankendancer QUIC ingress port directly for maximum throughput.

1. **Direct QUIC Path**: Use `solana_client` with QUIC enabled (default in modern SDKs).
2. **Commitment Level**: Use `Processed` for real-time trade matching feedback, `Confirmed` for settlement logic.
3. **Transaction Batching**: Leverage Firedancer's ability to handle massive bursts by batching IoT energy data packets before signing.
