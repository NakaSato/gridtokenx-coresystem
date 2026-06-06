# Energy Trading Agent Operations

This workflow guides you through the deployment, monitoring, and simulation of the `gridtokenx-agent-trade` service.

## 1. Development & Build

### Running Tests
Verify the seven core features (DCA, Grid Stability, Risk, etc.):
```bash
cd gridtokenx-agent-trade
cargo test
```

### Building the Container
Build the optimized production image:
```bash
docker build -t gridtokenx-agent-trade:latest .
```

## 2. Configuration

Ensure the following environment variables are set in your `.env` or deployment manifest:

| Variable | Description | Example |
|----------|-------------|---------|
| `AGENT_PRIVATE_KEY` | ED25519 Private Key (Base58/Hex) | `5K...` (Solana) |
| `PLATFORM_TRADING_URL` | ConnectRPC Trading Service | `http://trading:50051` |
| `KAFKA_BOOTSTRAP_SERVERS`| Market/Grid Event Source | `localhost:9092` |
| `RUST_LOG` | Logging Level | `info` |

## 3. Monitoring

The agent exposes a Prometheus scrape endpoint on port `9091`.

### Check Metrics Manually
```bash
curl http://localhost:9091/metrics
```

### Key Metrics to Watch
- `agent_daily_pnl_usd`: Real-time trading profitability.
- `agent_grid_load_pct`: Current grid stress level (Discharge triggers at >90%).
- `agent_risk_rejections_total`: Number of orders blocked by safety circuit breakers.

## 4. Simulation Testing

### Triggering Grid Stress
To test the "Good Grid Citizen" mode, publish a stress event to Kafka:
```bash
# Using kcat (formerly kafkacat)
echo '{"frequency": 49.5, "load_pct": 95.0, "is_stressed": true}' | \
  kcat -b localhost:9092 -t grid.health -P
```
*Expected Result: Agent should immediately pause DCA and discharge (sell) all energy inventory.*

### Simulating a Price Dip
To test "Buy the Dip" logic:
```bash
echo '{"symbol": "ENERGY", "price": "10.50", "timestamp": 123456789}' | \
  kcat -b localhost:9092 -t market.data -P
```
*(If previous price was >11.00, agent should trigger a BUY order).*

## 5. Troubleshooting

If the agent is not trading:
1. Check the `agent.db` (SQLite) for order status:
   ```bash
   sqlite3 agent.db "SELECT * FROM orders ORDER BY created_at DESC LIMIT 5;"
   ```
2. Verify the `RiskActor` logs:
   `Order REJECTED: Position limit exceeded` (Check `max_position_size` in code/config).
3. Ensure the `AGENT_PRIVATE_KEY` is a valid Solana-format key.
