---
description: Run and manage the Smart Meter Simulator
---

# Smart Meter Simulator

The Smart Meter Simulator is a Python-based utility that generates synthetic energy generation and consumption data, simulating thousands of IoT devices for platform stress testing.

## Quick Start

// turbo

```bash
# Start simulator services (Connects to Kafka/PostgreSQL)
./scripts/app.sh start --simulator
```

## Architecture

The simulator mimics real-world energy patterns and signs telemetry using Ed25519 keys (for the **Oracle Bridge**).

| Component | Port | Technology |
|-----------|------|------------|
| **Simulator API** | 8082 | Python/FastAPI (managed by `uv`) |
| **Simulator UI** | 5173 | React/Vite |

### Data Flow
```
Simulator → Oracle Bridge (Validation) → Kafka → API services → PostgreSQL
```

## Management (uv)

GridTokenX uses `uv` for Python dependency management. To run the simulator natively:

```bash
cd gridtokenx-smartmeter-simulator
uv run start
```

To run the UI natively:
```bash
cd gridtokenx-smartmeter-simulator/ui
npm install && npm run dev
```

## Simulation Controls

Access the dashboard at **http://localhost:5173**.

### API Controls
Target the simulator directly to automate load profiles:

```bash
# Start a 50-meter residential simulation
curl -X POST http://localhost:8082/api/v1/simulate \
  -H "Content-Type: application/json" \
  -d '{"mode": "realtime", "meters": 50, "pattern": "residential"}'

# Stop all active simulations
curl -X POST http://localhost:8082/api/v1/simulate/stop
```

## Configuration

The simulator configuration is located in `gridtokenx-smartmeter-simulator/.env`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `KAFKA_BOOTSTRAP_SERVERS` | `kafka:9092` | Where to push raw readings |
| `ORACLE_BRIDGE_URL` | `http://oracle-bridge:4010` | Where to send readings for signing |
| `METERS_COUNT` | `100` | Number of virtual devices |

## Troubleshooting

- **No Data in Explorer**: Check if the `oracle-bridge` is running. The simulator sends data to the bridge first for crypto-validation.
- **Kafka Timeout**: Ensure the `gridtokenx-kafka` container is healthy (`./scripts/app.sh status`).
- **Python Errors**: Ensure you have `uv` installed and run `uv sync` in the simulator directory.

## Related Workflows
- [Oracle Bridge](./oracle-bridge-development.md) - How readings are validated.
- [Monitoring](./monitoring.md) - Visualizing simulator data in Grafana.
- [Start Development](./start-dev.md) - Standard platform startup.
tainers
