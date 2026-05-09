# BlockBench Benchmark Results

This document summarizes the performance results of the GridTokenX Anchor smart contracts under various workloads using the BlockBench suite.

## Execution Metadata
- **Timestamp**: 2026-05-09T00:27:52.504Z
- **Project**: `gridtokenx-anchor`
- **Solana Cluster**: `localnet`
- **Wallet**: `D21VTEm2mwmKnN4e8ygNfZPtzDXMfPWHGz3vXaMeqL8X`

## Summary Metrics
| Metric | Value |
|--------|-------|
| Total Tests | 15 |
| Passed | 14 |
| Failed | 1 |
| Avg Latency | 44.49 ms |
| Avg Compute Units | 7,755 CU |

## Detailed Results by Category

### Baseline (Transaction Overhead)
| Test Name | Latency (ms) | Compute Units | Success |
|-----------|--------------|---------------|---------|
| `do_nothing` | 11.82 | 648 | ✅ |
| `do_nothing_nonce` | 10.48 | 938 | ✅ |

### CPU Heavy (Instruction Throughput)
| Test Name | Latency (ms) | Compute Units | Success |
|-----------|--------------|---------------|---------|
| `cpu_heavy_hash` | 14.36 | 69,805 | ✅ |
| `cpu_heavy_loop` | 9.31 | 1,051 | ✅ |
| `cpu_heavy_matrix` | -1 | -1 | ❌ (Exceeded Compute Budget) |
| `cpu_heavy_sort` | 9.40 | 8,195 | ✅ |

### I/O Heavy (Account Storage Read/Write)
| Test Name | Latency (ms) | Compute Units | Success |
|-----------|--------------|---------------|---------|
| `io_heavy_read` | 11.52 | 2,475 | ✅ |
| `io_heavy_write` | 10.81 | 1,020 | ✅ |
| `io_heavy_mixed` | 10.13 | 1,559 | ✅ |

### YCSB (Key-Value Store Operations)
| Test Name | Latency (ms) | Compute Units | Success |
|-----------|--------------|---------------|---------|
| `ycsb_insert` | 493.40 | 6,359 | ✅ |
| `ycsb_read` | 2.15 | 0 | ✅ |
| `ycsb_update` | 9.83 | 3,148 | ✅ |
| `ycsb_delete` | 10.43 | 2,980 | ✅ |

### Analytics (Data Aggregation & Scanning)
| Test Name | Latency (ms) | Compute Units | Success |
|-----------|--------------|---------------|---------|
| `analytics_aggregate` | 9.63 | 1,325 | ✅ |
| `analytics_scan` | 9.60 | 1,318 | ✅ |

## Analysis & Observations
1. **Compute Budget Constraints**: The `cpu_heavy_matrix` test failed, indicating that matrix operations in Anchor/Solana reach the default compute budget limits quickly. Optimization or custom compute budget allocation is required for complex mathematical tasks.
2. **I/O Efficiency**: Read and write operations remain extremely efficient, with latency staying around 10ms and minimal CU consumption.
3. **Insert Latency**: `ycsb_insert` shows a significantly higher latency (493ms) compared to other operations, likely due to account initialization and allocation overhead on the Solana runtime.
4. **Read Performance**: `ycsb_read` achieved near-zero CU consumption and very low latency, demonstrating highly optimized lookup performance.

## Next Steps
- Optimize `cpu_heavy_matrix` implementation or increase compute budget for analytical tasks.
- Investigate the high latency in `ycsb_insert` to determine if it's a bottleneck for high-frequency data ingestion.
- Profile `cpu_heavy_hash` to reduce CU consumption if possible.
