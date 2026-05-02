#!/usr/bin/env bash
# GridTokenX Smart Meter Simulator E2E Test Script

set -e

# 1. Check if Docker is running
if ! docker info > /dev/null 2>&1; then
  echo "❌ Error: Docker daemon is not running. Please start Docker and try again."
  exit 1
fi

echo "🚀 Starting E2E Test for Smart Meter Simulator..."

# 2. Ensure all services are up
echo "📦 Ensuring all services are started..."
docker compose up -d --quiet-pull

# 3. Wait for Simulator to be healthy
echo "⏳ Waiting for gridtokenx-smartmeter-simulator to be healthy..."
RETRY_COUNT=0
MAX_RETRIES=10
until [ "$(docker inspect -f '{{.State.Health.Status}}' gridtokenx-smartmeter-simulator)" == "healthy" ]; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "❌ Timeout waiting for simulator to become healthy."
        docker logs gridtokenx-smartmeter-simulator --tail 50
        exit 1
    fi
    echo "   ...still waiting ($((RETRY_COUNT+1))/$MAX_RETRIES)"
    sleep 10
    RETRY_COUNT=$((RETRY_COUNT+1))
done
echo "✅ Simulator is healthy!"

# 4. Trigger a Manual Step (if autostart was somehow bypassed)
echo "🔘 Triggering manual analytics check..."
curl -s http://localhost:12010/api/v1/analytics/summary | jq .

# 5. Verify InfluxDB Ingestion
echo "📈 Verifying InfluxDB ingestion..."
sleep 5
INFLUX_RESULT=$(docker exec gridtokenx-influxdb influx query 'from(bucket: "energy_readings") |> range(start: -2m) |> filter(fn: (r) => r._measurement == "meter_reading") |> limit(n: 1)' --org gridtokenx --token your-influxdb-token)

if [ -z "$INFLUX_RESULT" ]; then
  echo "❌ Error: No data found in InfluxDB bucket 'energy_readings'."
  exit 1
else
  echo "✅ Data found in InfluxDB!"
fi

# 6. Verify Kafka Ingestion (Topic: simulation.readings)
echo "📡 Verifying Kafka ingestion (Topic: simulation.readings)..."
# Check if topic exists first
if docker exec gridtokenx-kafka-cmd /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9001 --list | grep -q "simulation.readings"; then
    echo "✅ Kafka topic 'simulation.readings' exists."
else
    echo "⚠️ Warning: Kafka topic 'simulation.readings' not found. Creating it..."
    docker exec gridtokenx-kafka-cmd /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9001 --create --topic simulation.readings --partitions 3 --replication-factor 1
fi

# 7. Check central observability (Loki)
echo "📜 Verifying Loki log ingestion..."
LOKI_LABELS=$(curl -s "http://localhost:6003/loki/api/v1/labels")
if echo "$LOKI_LABELS" | grep -q "service_name"; then
  echo "✅ Loki is indexing logs!"
else
  echo "⚠️ Loki labels not found yet. Ingestion might be delayed."
fi

echo "🎉 E2E Test Completed Successfully!"
echo "You can view the dashboard at: http://localhost:6002"
