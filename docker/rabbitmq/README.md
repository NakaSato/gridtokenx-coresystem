# RabbitMQ Setup for GridTokenX

## Overview

RabbitMQ (`rabbitmq:3.13-management-alpine`, compose service `rabbitmq`) is used for **task
queues**, **async job processing**, and **guaranteed message delivery** in the GridTokenX platform.

### Use Cases
- Email notifications (welcome, password reset)
- Settlement retry queues (with priority)
- Meter validation jobs
- Batch processing jobs
- Webhook deliveries

---

## Quick Start

### 1. Start RabbitMQ

```bash
docker compose up -d rabbitmq
```

### 2. Access Management UI

- **URL**: http://localhost:9031
- **Username**: `gridtokenx`
- **Password**: `rabbitmq_secret_2025`

### 3. Verify Setup

```bash
# Check RabbitMQ status
docker exec gridtokenx-rabbitmq rabbitmq-diagnostics ping

# List queues / exchanges / bindings
docker exec gridtokenx-rabbitmq rabbitmqadmin list queues
docker exec gridtokenx-rabbitmq rabbitmqadmin list exchanges
docker exec gridtokenx-rabbitmq rabbitmqadmin list bindings
```

---

## Architecture

### Exchanges

| Exchange | Type | Purpose |
|----------|------|---------|
| `notifications` | Topic | Email and notification routing |
| `trading` | Topic | Trading-related task queues |
| `aggregator` | Topic | Aggregator and meter validation |
| `scheduler` | Topic | Scheduled and batch jobs |
| `integrations` | Topic | External integrations (webhooks) |
| `dlx.exchange` | Direct | Dead letter exchange |

### Queues

| Queue | Exchange | Routing Key | Priority | DLQ |
|-------|----------|-------------|----------|-----|
| `email.notifications` | notifications | `email.*` | No | ✅ |
| `password.resets` | notifications | — (no binding defined in `definitions.json`) | No | ✅ |
| `settlement.retries` | trading | `settlement.retry` | 1-10 | ✅ |
| `meter.validation` | aggregator | `meter.validate` | No | ✅ |
| `batch.jobs` | scheduler | `batch.*` | No | ✅ |
| `webhook.deliveries` | integrations | `webhook.*` | No | ✅ |

---

## Configuration Files

```
docker/rabbitmq/
├── rabbitmq.conf           # Main configuration (mounted read-only)
├── enabled_plugins         # rabbitmq_management, rabbitmq_prometheus, rabbitmq_tracing (mounted read-only)
├── definitions.json        # Exchange/queue/binding definitions — NOT auto-loaded (see below)
└── init-rabbitmq.sh        # Manual initialization script (declares exchanges/queues/bindings via rabbitmqadmin)
```

> **Note:** `definitions.json` is currently **not loaded at boot** — both its compose bind-mount
> and the `management.load_definitions` line in `rabbitmq.conf` are commented out. To provision the
> topology, run `./docker/rabbitmq/init-rabbitmq.sh` (or re-enable definition loading). Known drift:
> the init script binds `meter.validation` to a source exchange named `oracle`, while
> `definitions.json` binds it to `aggregator`.

---

## Environment Variables

```bash
# RabbitMQ Configuration (compose defaults)
RABBITMQ_PORT=9030                    # Host AMQP port (container 5672)
RABBITMQ_MGMT_PORT=9031               # Host Management UI port
RABBITMQ_DEFAULT_USER=gridtokenx      # Admin username
RABBITMQ_DEFAULT_PASS=rabbitmq_secret_2025  # Admin password

# From the host:
RABBITMQ_URL=amqp://gridtokenx:rabbitmq_secret_2025@localhost:9030
# In-network (what services receive in docker-compose.yml):
RABBITMQ_URL=amqp://gridtokenx:rabbitmq_secret_2025@rabbitmq:5672
```

---

## Rust Integration

### Add Dependencies

```toml
# Cargo.toml
[dependencies]
lapin = "2.5"  # RabbitMQ client
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

### Producer Example

```rust
use lapin::{
    options::*, types::FieldTable, Connection, ConnectionProperties, ExchangeKind, BasicProperties,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let addr = "amqp://gridtokenx:rabbitmq_secret_2025@localhost:9030";
    let conn = Connection::connect(addr, ConnectionProperties::default()).await?;
    let channel = conn.create_channel().await?;

    // Declare exchange
    channel.exchange_declare(
        "notifications",
        ExchangeKind::Topic,
        lapin::options::ExchangeDeclareOptions::default(),
        FieldTable::default(),
    ).await?;

    // Publish message
    let payload = br#"{"user_id": "123", "email": "user@example.com", "type": "welcome"}"#;

    channel.basic_publish(
        "notifications",
        "email.welcome",
        lapin::options::BasicPublishOptions::default(),
        payload,
        BasicProperties::default()
            .delivery_mode(lapin::BasicProperties::delivery_mode(2)), // Persistent
    ).await?;

    Ok(())
}
```

### Consumer Example

```rust
use lapin::{
    options::*, types::FieldTable, Connection, ConnectionProperties,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let addr = "amqp://gridtokenx:rabbitmq_secret_2025@localhost:9030";
    let conn = Connection::connect(addr, ConnectionProperties::default()).await?;
    let channel = conn.create_channel().await?;

    // Consume from queue
    let mut consumer = channel.basic_consume(
        "email.notifications",
        "email_worker",
        BasicConsumeOptions::default(),
        FieldTable::default(),
    ).await?;

    while let Some(delivery) = consumer.next().await {
        let delivery = delivery?;
        let data = std::str::from_utf8(&delivery.data)?;
        println!("Received: {}", data);

        // Process email...

        // Acknowledge
        delivery.ack(BasicAckOptions::default()).await?;
    }

    Ok(())
}
```

---

## Monitoring

### Management UI

Access at http://localhost:9031 to monitor queue depths, message rates, consumer connections,
and channel activity.

### Prometheus Metrics

The `rabbitmq_prometheus` plugin is enabled (`enabled_plugins`, and `rabbitmq.conf` sets
`prometheus.return_per_object_metrics = true`). Note: the repo's
`docker/prometheus/prometheus.yml` does **not** currently include a RabbitMQ scrape job; to scrape
it, add one, e.g.:

```yaml
scrape_configs:
  - job_name: 'rabbitmq'
    static_configs:
      - targets: ['rabbitmq:9031']
    metrics_path: '/api/metrics'
    basic_auth:
      username: 'gridtokenx'
      password: 'rabbitmq_secret_2025'
```

---

## Troubleshooting

### Check RabbitMQ Status

```bash
docker exec gridtokenx-rabbitmq rabbitmqctl status
```

The compose healthcheck uses `rabbitmq-diagnostics -q check_port_connectivity` (a plain `ping`
does not prove AMQP readiness).

### View Logs

```bash
docker logs -f gridtokenx-rabbitmq
```

### Reset RabbitMQ

```bash
docker compose down rabbitmq
docker volume rm gridtokenx-coresystem_rabbitmq_data
docker compose up -d rabbitmq
```

### Re-initialize Queues

```bash
docker exec gridtokenx-rabbitmq rabbitmqctl stop_app
docker exec gridtokenx-rabbitmq rabbitmqctl reset
docker exec gridtokenx-rabbitmq rabbitmqctl start_app
./docker/rabbitmq/init-rabbitmq.sh
```

---

## Production Considerations

### Security
- Enable TLS for AMQP connections (commented template in `rabbitmq.conf`)
- Use strong passwords
- Restrict management UI access
- Enable authentication mechanisms

### High Availability
- Enable quorum queues
- Set up clustering (minimum 3 nodes)
- Configure mirrored queues
- Enable publisher confirms

### Performance
- Adjust memory watermark (dev default: `vm_memory_high_watermark.relative = 0.6`)
- Configure disk free limits (dev default: `disk_free_limit.absolute = 50MB`)
- Enable lazy queues for large queues
- Monitor consumer lag

### Monitoring
- Set up alerts for queue depth
- Monitor DLQ size
- Track message rates
- Alert on unacknowledged messages

---

## Migration from Redis Streams

If migrating from Redis Streams to RabbitMQ:

1. **Deploy RabbitMQ alongside Redis** (dual-write phase)
2. **Update producers** to publish to both Redis and RabbitMQ
3. **Migrate consumers** one at a time to read from RabbitMQ
4. **Validate** message delivery and ordering
5. **Remove** Redis Streams usage
6. **Keep** Redis Pub/Sub for WebSocket broadcasts

---

## Documentation

- [RabbitMQ Official Docs](https://www.rabbitmq.com/documentation.html)
- [Lapin Rust Client](https://github.com/CleverCloud/lapin)
- [GridTokenX Messaging Architecture](../../ARCHITECTURE.md) — §6 Messaging, Persistence & Resilience
