# Stateful backing infrastructure: Postgres, PgDog, Redis, Kafka x3, RabbitMQ,
# NATS, Vault, Mailpit, InfluxDB. Mirrors docker-compose.yml semantics; `wait`
# on healthchecked containers reproduces compose `condition: service_healthy`
# gating for dependents declared via depends_on.

resource "docker_container" "postgres" {
  name    = "gridtokenx-postgres"
  image   = docker_image.pulled["postgres"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "POSTGRES_DB=${local.env["POSTGRES_DB"]}",
    "POSTGRES_USER=${local.env["POSTGRES_USER"]}",
    "POSTGRES_PASSWORD=${local.env["POSTGRES_PASSWORD"]}",
    "TZ=${local.tz}",
  ]

  command = [
    "postgres",
    "-c", "max_connections=200",
    "-c", "shared_buffers=256MB",
    "-c", "effective_cache_size=1GB",
    "-c", "work_mem=16MB",
    "-c", "maintenance_work_mem=64MB",
    "-c", "random_page_cost=1.1",
    "-c", "effective_io_concurrency=200",
    "-c", "wal_buffers=16MB",
    "-c", "checkpoint_completion_target=0.9",
    "-c", "log_statement=mod",
    "-c", "log_duration=on",
    "-c", "log_min_duration_statement=1000",
    "-c", "shared_preload_libraries=pg_stat_statements",
    # Safe `on` default; dev opts into async commit via PG_SYNCHRONOUS_COMMIT in .env.
    "-c", "synchronous_commit=${coalesce(lookup(local.env, "PG_SYNCHRONOUS_COMMIT", ""), "on")}",
  ]

  ports {
    internal = 5432
    external = tonumber(coalesce(lookup(local.env, "POSTGRES_PRIMARY_PORT", ""), "7001"))
  }

  volumes {
    volume_name    = docker_volume.this["postgres_data"].name
    container_path = "/var/lib/postgresql/data"
  }
  volumes {
    host_path      = "${local.repo_root}/scripts/init-multi-db.sql"
    container_path = "/docker-entrypoint-initdb.d/init-multi-db.sql"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["postgres"]
  }

  memory = 2048

  healthcheck {
    test     = ["CMD-SHELL", "pg_isready -U ${local.env["POSTGRES_USER"]} -d ${local.env["POSTGRES_DB"]}"]
    interval = "10s"
    timeout  = "5s"
    retries  = 5
  }
  wait = true
}

resource "docker_container" "pgdog" {
  name    = "gridtokenx-pgdog"
  image   = docker_image.pulled["pgdog"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  command = ["pgdog", "--config", "/etc/pgdog/pgdog.toml", "--users", "/etc/pgdog/users.toml"]

  volumes {
    host_path      = "${local.repo_root}/docker/pgdog/pgdog.toml"
    container_path = "/etc/pgdog/pgdog.toml"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/docker/pgdog/users.toml"
    container_path = "/etc/pgdog/users.toml"
    read_only      = true
  }

  ports {
    internal = 6432
    external = tonumber(coalesce(lookup(local.env, "PGDOG_PORT", ""), "7003"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["pgdog"]
  }

  memory = 256

  healthcheck {
    test     = ["CMD", "curl", "-sf", "http://127.0.0.1:9000/"]
    interval = "10s"
    timeout  = "5s"
    retries  = 5
  }
  wait = true

  depends_on = [docker_container.postgres]
}

resource "docker_container" "redis" {
  name    = "gridtokenx-redis"
  image   = docker_image.pulled["redis"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  # AOF: device pubkeys survive hard restarts (see compose comment).
  command = [
    "redis-server", "--appendonly", "yes", "--appendfsync", "everysec",
    "--save", "3600 1 300 100 60 10000",
  ]

  env = ["TZ=${local.tz}"]

  ports {
    internal = 6379
    external = tonumber(coalesce(lookup(local.env, "REDIS_PRIMARY_PORT", ""), "7010"))
  }

  volumes {
    volume_name    = docker_volume.this["redis_data"].name
    container_path = "/data"
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["redis"]
  }

  memory = 2048

  healthcheck {
    test     = ["CMD", "redis-cli", "ping"]
    interval = "10s"
    timeout  = "3s"
    retries  = 5
  }
  wait = true
}

# Three single-node KRaft Kafka clusters: cmd (durable commands/events),
# market (high-TPS telemetry), audit (long retention).
locals {
  kafka = {
    cmd = {
      client_port = 9001
      host_port   = 29001
      ctrl_port   = 9004
      partitions  = 3
      retention_h = 168
      heap        = "-Xmx512m -Xms256m"
      memory      = 1024
      env_key     = "KAFKA_CMD_PORT"
    }
    market = {
      client_port = 9002
      host_port   = 29002
      ctrl_port   = 9005
      partitions  = 10
      retention_h = 24
      heap        = "-Xmx768m -Xms384m"
      memory      = 1280
      env_key     = "KAFKA_MARKET_PORT"
    }
    audit = {
      client_port = 9003
      host_port   = 29003
      ctrl_port   = 9006
      partitions  = 3
      retention_h = 168
      heap        = "-Xmx512m -Xms256m"
      memory      = 1024
      env_key     = "KAFKA_AUDIT_PORT"
    }
  }
}

resource "docker_container" "kafka" {
  for_each = local.kafka

  name    = "gridtokenx-kafka-${each.key}"
  image   = docker_image.pulled["kafka"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "TZ=${local.tz}",
    "KAFKA_NODE_ID=1",
    "KAFKA_PROCESS_ROLES=broker,controller",
    "KAFKA_CONTROLLER_QUORUM_VOTERS=1@kafka-${each.key}:${each.value.ctrl_port}",
    "KAFKA_LISTENERS=PLAINTEXT://:${each.value.client_port},PLAINTEXT_HOST://:${each.value.host_port},CONTROLLER://:${each.value.ctrl_port}",
    "KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka-${each.key}:${each.value.client_port},PLAINTEXT_HOST://localhost:${each.value.host_port}",
    "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT",
    "KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER",
    "KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT",
    "KAFKA_AUTO_CREATE_TOPICS_ENABLE=true",
    "KAFKA_NUM_PARTITIONS=${each.value.partitions}",
    "KAFKA_DEFAULT_REPLICATION_FACTOR=1",
    "KAFKA_LOG_RETENTION_HOURS=${each.value.retention_h}",
    "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1",
    "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1",
    "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1",
    "CLUSTER_ID=MkU3OEVBNTcwNTJENDM2Qk",
    # Bounded JVM heap so three brokers can't OOM the host (image default -Xmx1G).
    "KAFKA_HEAP_OPTS=${each.value.heap}",
  ]

  ports {
    internal = each.value.client_port
    external = tonumber(coalesce(lookup(local.env, each.value.env_key, ""), tostring(each.value.client_port)))
  }
  ports {
    internal = each.value.host_port
    external = each.value.host_port
  }

  volumes {
    volume_name    = docker_volume.this["kafka_${each.key}_data"].name
    container_path = "/var/lib/kafka/data"
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["kafka-${each.key}"]
  }

  memory = each.value.memory

  healthcheck {
    test         = ["CMD", "nc", "-z", "localhost", tostring(each.value.client_port)]
    interval     = "30s"
    timeout      = "10s"
    retries      = 5
    start_period = "30s"
  }
  wait         = true
  wait_timeout = 120
}

resource "docker_container" "rabbitmq" {
  name    = "gridtokenx-rabbitmq"
  image   = docker_image.pulled["rabbitmq"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "TZ=${local.tz}",
    "RABBITMQ_DEFAULT_USER=${local.rabbit_user}",
    "RABBITMQ_DEFAULT_PASS=${local.rabbit_pass}",
    "RABBITMQ_DEFAULT_VHOST=/",
    "RABBITMQ_VM_MEMORY_HIGH_WATERMARK_RELATIVE=0.6",
    "RABBITMQ_DISK_FREE_LIMIT=50MB",
    "RABBITMQ_PLUGINS=rabbitmq_management rabbitmq_prometheus",
  ]

  ports {
    internal = 5672
    external = tonumber(coalesce(lookup(local.env, "RABBITMQ_PORT", ""), "9030"))
  }
  ports {
    internal = 15672
    external = tonumber(coalesce(lookup(local.env, "RABBITMQ_MGMT_PORT", ""), "9031"))
  }

  volumes {
    volume_name    = docker_volume.this["rabbitmq_data"].name
    container_path = "/var/lib/rabbitmq"
  }
  volumes {
    host_path      = "${local.repo_root}/docker/rabbitmq/rabbitmq.conf"
    container_path = "/etc/rabbitmq/rabbitmq.conf"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/docker/rabbitmq/enabled_plugins"
    container_path = "/etc/rabbitmq/enabled_plugins"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["rabbitmq"]
  }

  memory = 1024

  healthcheck {
    # check_port_connectivity: 5672 actually accepts (not just Erlang node up).
    test         = ["CMD-SHELL", "rabbitmq-diagnostics -q check_port_connectivity"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 5
    start_period = "60s"
  }
  wait         = true
  wait_timeout = 180
}

resource "docker_container" "nats" {
  name    = "gridtokenx-nats"
  image   = docker_image.pulled["nats"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  command = ["--jetstream", "--store_dir=/data", "--http_port=8222"]

  ports {
    internal = 4222
    external = tonumber(coalesce(lookup(local.env, "NATS_CLIENT_PORT", ""), "9020"))
  }
  ports {
    internal = 8222
    external = tonumber(coalesce(lookup(local.env, "NATS_MONITOR_PORT", ""), "9021"))
  }

  volumes {
    volume_name    = docker_volume.this["nats_data"].name
    container_path = "/data"
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["nats"]
  }

  memory = 384

  healthcheck {
    test         = ["CMD", "wget", "--spider", "-q", "http://localhost:8222/healthz"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 5
    start_period = "10s"
  }
  wait = true
}

resource "docker_container" "vault" {
  name    = "gridtokenx-vault"
  image   = docker_image.pulled["vault"].image_id
  restart = "unless-stopped"
  # no-new-privileges intentionally omitted: vault binary carries the
  # cap_ipc_lock file capability (mlock); no_new_privs blocks file-cap grants.

  env = [
    "VAULT_DEV_ROOT_TOKEN_ID=root",
    "VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200",
  ]

  ports {
    internal = 8200
    external = tonumber(coalesce(lookup(local.env, "VAULT_PORT", ""), "13001"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["vault"]
  }

  memory = 256

  healthcheck {
    test     = ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:8200/v1/sys/health"]
    interval = "10s"
    timeout  = "5s"
    retries  = 5
  }
  wait = true
}

resource "docker_container" "mailpit" {
  name    = "gridtokenx-mailpit"
  image   = docker_image.pulled["mailpit"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "MP_MAX_MESSAGES=${local.env["MP_MAX_MESSAGES"]}",
    "MP_DATABASE=${local.env["MP_DATABASE"]}",
    "MP_SMTP_AUTH_ACCEPT_ANY=${local.env["MP_SMTP_AUTH_ACCEPT_ANY"]}",
    "MP_SMTP_AUTH_ALLOW_INSECURE=${local.env["MP_SMTP_AUTH_ALLOW_INSECURE"]}",
    "TZ=${local.tz}",
  ]

  ports {
    internal = 1025
    external = tonumber(coalesce(lookup(local.env, "MAILPIT_SMTP_PORT", ""), "1025"))
  }
  ports {
    internal = 8025
    external = tonumber(coalesce(lookup(local.env, "MAILPIT_WEB_PORT", ""), "13060"))
  }

  volumes {
    volume_name    = docker_volume.this["mailpit_data"].name
    container_path = "/data"
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["mailpit"]
  }

  memory = 128

  healthcheck {
    test     = ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8025/api/v1/info"]
    interval = "30s"
    timeout  = "10s"
    retries  = 3
  }
  wait = true
}

# Dedicated InfluxDB v2 — Aggregator Bridge realtime telemetry history ONLY.
resource "docker_container" "aggregator_influxdb" {
  name    = "gridtokenx-aggregator-influxdb"
  image   = docker_image.pulled["influxdb"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "DOCKER_INFLUXDB_INIT_MODE=setup",
    "DOCKER_INFLUXDB_INIT_USERNAME=${coalesce(lookup(local.env, "AGGREGATOR_INFLUXDB_USER", ""), "gridtokenx")}",
    "DOCKER_INFLUXDB_INIT_PASSWORD=${coalesce(lookup(local.env, "AGGREGATOR_INFLUXDB_PASSWORD", ""), "aggregator-influx-dev-pw")}",
    "DOCKER_INFLUXDB_INIT_ORG=${coalesce(lookup(local.env, "INFLUXDB_ORG", ""), "gridtokenx")}",
    "DOCKER_INFLUXDB_INIT_BUCKET=${coalesce(lookup(local.env, "INFLUXDB_BUCKET", ""), "aggregator_telemetry")}",
    "DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${coalesce(lookup(local.env, "AGGREGATOR_INFLUXDB_TOKEN", ""), "aggregator-bridge-dev-token")}",
  ]

  ports {
    internal = 8086
    external = tonumber(coalesce(lookup(local.env, "AGGREGATOR_INFLUXDB_PORT", ""), "8087"))
  }

  volumes {
    volume_name    = docker_volume.this["aggregator-influxdb-data"].name
    container_path = "/var/lib/influxdb2"
  }
  volumes {
    volume_name    = docker_volume.this["aggregator-influxdb-config"].name
    container_path = "/etc/influxdb2"
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["aggregator-influxdb"]
  }

  memory = 1024

  healthcheck {
    test         = ["CMD", "influx", "ping"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 5
    start_period = "20s"
  }
  wait = true
}
