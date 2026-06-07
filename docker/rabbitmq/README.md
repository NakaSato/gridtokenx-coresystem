# RabbitMQ Setup for GridTokenX

## Overview

RabbitMQ is used for **task queues**, **async job processing**, and **guaranteed message delivery** in the GridTokenX platform.

### Use Cases
- ✅ Email notifications (welcome, password reset)
- ✅ Settlement retry queues (with priority)
- ✅ Meter validation jobs
- ✅ Batch processing jobs
- ✅ Webhook deliveries

---

## Quick Start

### 1. Start RabbitMQ

```bash
docker-compose up -d rabbitmq
```

### 2. Access Management UI

- **URL**: http://localhost:9031
- **Username**: `gridtokenx`
- **Password**: `rabbitmq_secret_2025`

### 3. Verify Setup

```bash
# Check RabbitMQ status
docker exec gridtokenx-rabbitmq rabbitmq-diagnostics ping

# List queues
docker exec gridtokenx-rabbitmq rabbitmqadmin list queues

# List exchanges
docker exec gridtokenx-rabbitmq rabbitmqadmin list exchanges

# List bindings
docker exec gridtokenx-rabbitmq rabbitmqadmin list bindings
```

---

## Architecture

### Exchanges

| Exchange | Type | Purpose |
|----------|------|---------|
| `notifications` | Topic | Email and notification routing |
| `trading` | Topic | Trading-related task queues |
| `oracle` | Topic | Oracle and meter validation |
| `scheduler` | Topic | Scheduled and batch jobs |
| `integrations` | Topic | External integrations (webhooks) |
| `dlx.exchange` | Direct | Dead letter exchange |

### Queues

| Queue | Exchange | Routing Key | Priority | DLQ |
|-------|----------|-------------|----------|-----|
| `email.notifications` | notifications | `email.*` | No | ✅ |
| `password.resets` | notifications | `password.reset` | No | ✅ |
| `settlement.retries` | trading | `settlement.retry` | 1-10 | ✅ |
| `meter.validation` | oracle | `meter.validate` | No | ✅ |
| `batch.jobs` | scheduler | `batch.*` | No | ✅ |
| `webhook.deliveries` | integrations | `webhook.*` | No | ✅ |

---

## Configuration Files

```
docker/rabbitmq/
├── rabbitmq.conf           # Main configuration
├── enabled_plugins         # Enabled plugins list
├── definitions.json        # Pre-configured exchanges, queues, bindings
└── init-rabbitmq.sh       # Initialization script
```

---

## Environment Variables

```bash
# RabbitMQ Configuration
RABBITMQ_PORT=9030                    # AMQP port
RABBITMQ_MGMT_PORT=9031              # Management UI port
RABBITMQ_DEFAULT_USER=gridtokenx      # Admin username
RABBITMQ_DEFAULT_PASS=rabbitmq_secret_2025  # Admin password
RABBITMQ_URL=amqp://gridtokenx:rabbitmq_secret_2025@localhost:9030
RABBITMQ_ENABLED=true
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

Access at http://localhost:9031 to monitor:
- Queue depths
- Message rates
- Consumer connections
- Channel activity

### Prometheus Metrics

RabbitMQ exposes metrics at:
```
http://localhost:9031/api/metrics
```

Add to `prometheus.yml`:
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

### View Logs

```bash
docker logs -f gridtokenx-rabbitmq
```

### Reset RabbitMQ

```bash
docker-compose down rabbitmq
docker volume rm gridtokenx-platform-infa_rabbitmq_data
docker-compose up -d rabbitmq
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
- ✅ Enable TLS for AMQP connections
- ✅ Use strong passwords
- ✅ Restrict management UI access
- ✅ Enable authentication mechanisms

### High Availability
- ✅ Enable quorum queues
- ✅ Set up clustering (minimum 3 nodes)
- ✅ Configure mirrored queues
- ✅ Enable publisher confirms

### Performance
- ✅ Adjust memory watermark
- ✅ Configure disk free limits
- ✅ Enable lazy queues for large queues
- ✅ Monitor consumer lag

### Monitoring
- ✅ Set up alerts for queue depth
- ✅ Monitor DLQ size
- ✅ Track message rates
- ✅ Alert on unacknowledged messages

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
- [GridTokenX Messaging Architecture](../../ARCHITECTURE.md) — §6 Messaging & Persistence
