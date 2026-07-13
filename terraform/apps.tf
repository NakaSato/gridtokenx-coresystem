# Application services. Images are compose-built (`docker compose build`);
# Terraform manages the runtime containers. depends_on + `wait` on the
# dependency mirrors compose `condition: service_healthy`.

# Apache APISIX — user gateway (public / web clients).
resource "docker_container" "apisix" {
  name    = "gridtokenx-apisix"
  image   = docker_image.pulled["apisix"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = ["APISIX_STAND_ALONE=true"]

  ports {
    internal = 9080
    external = 4001 # user proxy HTTP
  }
  ports {
    internal = 9443
    external = 8443 # user proxy HTTPS (self-signed dev cert)
  }
  ports {
    internal = 9180
    external = 8001 # admin HTTP
  }

  volumes {
    host_path      = "${local.repo_root}/apisix_conf/apisix.yaml"
    container_path = "/usr/local/apisix/conf/apisix.yaml"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/apisix_conf/config.yaml"
    container_path = "/usr/local/apisix/conf/config.yaml"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["apisix"]
  }
  networks_advanced {
    name = docker_network.user_tier.name
  }

  memory = 512

  healthcheck {
    test     = ["CMD", "/bin/bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/9080"]
    interval = "10s"
    timeout  = "5s"
    retries  = 3
  }
  wait = true

  depends_on = [docker_container.postgres, docker_container.redis]
}

# Chain Bridge — the ONLY service touching Solana RPC. Signs via Vault Transit.
resource "docker_container" "chain_bridge" {
  name    = "gridtokenx-chain-bridge"
  image   = local.built_image.chain_bridge
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [for k, v in {
    OTEL_EXPORTER_OTLP_ENDPOINT = local.otel
    CHAIN_BRIDGE_GRPC_PORT      = "5040"
    # Settlement-TPS tuning; skip-preflight safe (idempotent behind durable outbox).
    CHAIN_BRIDGE_MINT_CONCURRENCY       = coalesce(lookup(local.env, "CHAIN_BRIDGE_MINT_CONCURRENCY", ""), "64")
    CHAIN_BRIDGE_SUBMIT_CONCURRENCY     = coalesce(lookup(local.env, "CHAIN_BRIDGE_SUBMIT_CONCURRENCY", ""), "32")
    CHAIN_BRIDGE_SKIP_PREFLIGHT         = coalesce(lookup(local.env, "CHAIN_BRIDGE_SKIP_PREFLIGHT", ""), "true")
    CHAIN_BRIDGE_PRESIGN_DISABLE        = coalesce(lookup(local.env, "CHAIN_BRIDGE_PRESIGN_DISABLE", ""), "true")
    NTP_SERVERS                         = local.ntp_servers
    CHAIN_BRIDGE_INSECURE               = local.chain_bridge_insecure
    CHAIN_BRIDGE_REC_VALIDATOR_KEY_NAME = coalesce(lookup(local.env, "CHAIN_BRIDGE_REC_VALIDATOR_KEY_NAME", ""), "gridtokenx-rec-validator")
    CHAIN_BRIDGE_TLS_CERT               = "/app/infra/certs/server.crt"
    CHAIN_BRIDGE_TLS_KEY                = "/app/infra/certs/server.key"
    CHAIN_BRIDGE_TLS_CA                 = "/app/infra/certs/ca.crt"
    CHAIN_BRIDGE_REQUIRE_SIGNED_NATS    = coalesce(lookup(local.env, "CHAIN_BRIDGE_REQUIRE_SIGNED_NATS", ""), "true")
    SOLANA_RPC_URL                      = local.docker_solana_rpc
    NATS_URL                            = coalesce(lookup(local.env, "NATS_URL", ""), "nats://nats:4222")
    VAULT_ADDR                          = "http://vault:8200"
    VAULT_TOKEN                         = "root"
  } : "${k}=${v}"]

  ports {
    internal = 5040
    external = tonumber(coalesce(lookup(local.env, "CHAIN_BRIDGE_GRPC_PORT", ""), "5040"))
  }
  ports {
    internal = 9464
    external = tonumber(coalesce(lookup(local.env, "CHAIN_BRIDGE_METRICS_PORT", ""), "9464"))
  }

  volumes {
    host_path      = "${local.repo_root}/infra/certs/server.crt"
    container_path = "/app/infra/certs/server.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/server.key"
    container_path = "/app/infra/certs/server.key"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/ca.crt"
    container_path = "/app/infra/certs/ca.crt"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["chain-bridge"]
  }

  memory = 512

  healthcheck {
    test     = ["CMD", "/usr/bin/busybox", "nc", "-w", "1", "127.0.0.1", "5040"]
    interval = "10s"
    timeout  = "5s"
    retries  = 3
  }
  wait = true

  depends_on = [docker_container.nats, docker_container.vault]
}

resource "docker_container" "iam_service" {
  name    = "gridtokenx-iam-service"
  image   = local.built_image.iam_service
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [for k, v in merge(
    local.kafka_brokers_env,
    local.smtp_env,
    local.chain_bridge_client_env,
    local.solana_program_env,
    {
      DATABASE_URL = local.pg_url
      # Dedicated session-mode pooler alias so migrate's advisory lock can't
      # leak into the transaction-mode pool.
      MIGRATION_DATABASE_URL      = "postgresql://gridtokenx_user:gridtokenx_password@pgdog:6432/gridtokenx_migrate"
      OTEL_EXPORTER_OTLP_ENDPOINT = local.otel
      REDIS_URL                   = "redis://redis:6379"
      RABBITMQ_URL                = local.rabbitmq_url
      IAM_PORT                    = "8080"
      IAM_GRPC_PORT               = "8090"
      PORT                        = "8080"
      JWT_SECRET                  = local.env["JWT_SECRET"]
      JWT_EXPIRATION              = local.env["JWT_EXPIRATION"]
      RUST_LOG                    = "debug,librdkafka=warn"
      # Caps concurrent Argon2 hashes (OOM guard at register bursts).
      AUTH_CPU_SEMAPHORE_LIMIT = "16"
      ENCRYPTION_SECRET        = local.env["ENCRYPTION_SECRET"]
      API_KEY_SECRET           = local.env["API_KEY_SECRET"]
      ENVIRONMENT              = "development"
      IAM_VERIFY_AIRDROP_SOL   = coalesce(lookup(local.env, "IAM_VERIFY_AIRDROP_SOL", ""), "10")
      IAM_REGISTER_LIMIT       = coalesce(lookup(local.env, "IAM_REGISTER_LIMIT", ""), "10000,3600")
      IAM_LOGIN_LIMIT          = coalesce(lookup(local.env, "IAM_LOGIN_LIMIT", ""), "10000,60")
      IAM_VERIFY_LIMIT         = coalesce(lookup(local.env, "IAM_VERIFY_LIMIT", ""), "10000,60")
      NTP_SERVERS              = local.ntp_servers
      VAULT_ADDR               = "http://vault:8200"
      VAULT_TOKEN              = "root"
      VAULT_TRANSIT_KEY_NAME   = "gridtokenx-user-wallets"
      CHAIN_BRIDGE_SERVICE_IDENTITY = "spiffe://gridtokenx.th/prod/iam-service"
      SOLANA_PAYER_KEY              = local.env["SOLANA_PAYER_KEY"]
      ENERGY_TOKEN_MINT             = local.env["ENERGY_TOKEN_MINT"]
      CURRENCY_TOKEN_MINT           = local.env["CURRENCY_TOKEN_MINT"]
      SOLANA_CLUSTER                = local.solana_cluster
      AUTHORITY_WALLET_PATH         = "/app/dev-wallet.json"
      ENABLE_EMAIL_VERIFICATION     = "true"
      EMAIL_VERIFICATION_REQUIRED   = "true"
      EMAIL_VERIFICATION_BASE_URL   = "http://localhost:4001"
      OWS_VAULT_PATH                = "/var/lib/gridtokenx/ows-vault"
    }
  ) : "${k}=${v}"]

  ports {
    internal = 8080
    external = tonumber(coalesce(lookup(local.env, "IAM_HTTP_PORT", ""), "4010"))
  }
  ports {
    internal = 8090
    external = tonumber(coalesce(lookup(local.env, "IAM_GRPC_PORT", ""), "5010"))
  }

  volumes {
    host_path      = "${local.repo_root}/dev-wallet.json"
    container_path = "/app/dev-wallet.json"
  }
  volumes {
    volume_name    = docker_volume.this["iam_ows_vault"].name
    container_path = "/var/lib/gridtokenx/ows-vault"
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/ca.crt"
    container_path = "/app/infra/certs/ca.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/clients/iam-service.crt"
    container_path = "/app/infra/certs/client.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/clients/iam-service.key"
    container_path = "/app/infra/certs/client.key"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["iam-service"]
  }

  memory = 2048

  healthcheck {
    test         = ["CMD", "/usr/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/health"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 5
    start_period = "10s"
  }
  wait         = true
  wait_timeout = 180

  depends_on = [
    docker_container.pgdog,
    docker_container.rabbitmq,
    docker_container.chain_bridge,
  ]
}

# Meter Service — dashboard read API (meters + meter_readings).
resource "docker_container" "meter_service" {
  name    = "gridtokenx-meter-service"
  image   = local.built_image.meter_service
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "DATABASE_URL=${local.pg_url}",
    "JWT_SECRET=${local.env["JWT_SECRET"]}",
    "METER_SERVICE_PORT=8080",
    "RUST_LOG=info,sqlx=warn",
  ]

  ports {
    internal = 8080
    external = tonumber(coalesce(lookup(local.env, "METER_SERVICE_PORT", ""), "4062"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["meter-service"]
  }

  memory = 512

  healthcheck {
    test         = ["CMD", "curl", "-f", "http://localhost:8080/health"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 5
    start_period = "10s"
  }
  wait = true

  depends_on = [docker_container.pgdog]
}

resource "docker_container" "trading_service" {
  name    = "gridtokenx-trading-service"
  image   = local.built_image.trading_service
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  labels {
    # OrbStack domain must hit the REST API (8093), not the gRPC port.
    label = "dev.orbstack.http-port"
    value = "8093"
  }

  env = [for k, v in merge(
    local.kafka_brokers_env,
    local.smtp_env,
    local.chain_bridge_client_env,
    local.solana_program_env,
    {
      DATABASE_URL  = local.pg_url
      REDIS_URL     = "redis://redis:6379"
      KAFKA_BROKERS = "kafka-cmd:9001"
      # noti-service consumes `${KAFKA_TOPIC_PREFIX}.triggers` for price alerts.
      KAFKA_EVENTS_ENABLED        = "true"
      KAFKA_BOOTSTRAP_SERVERS     = "kafka-cmd:9001"
      KAFKA_TOPIC_PREFIX          = "trading"
      OTEL_EXPORTER_OTLP_ENDPOINT = local.otel
      NTP_SERVERS                 = local.ntp_servers
      RABBITMQ_URL                = local.rabbitmq_url
      RUST_LOG                    = "debug,librdkafka=warn"
      JWT_SECRET                  = local.env["JWT_SECRET"]
      ENCRYPTION_SECRET           = local.env["ENCRYPTION_SECRET"]
      SOLANA_RPC_URL              = local.docker_solana_rpc
      CHAIN_BRIDGE_SERVICE_IDENTITY = "spiffe://gridtokenx.th/prod/trading-service/api"
      SOLANA_PAYER_KEY              = local.env["SOLANA_PAYER_KEY"]
      SOLANA_WS_URL                 = coalesce(lookup(local.env, "SOLANA_WS_URL", ""), "ws://host.docker.internal:8002")
      IAM_SERVICE_URL               = "http://apisix:9080"
      INTERNAL_API_KEY              = local.engineering_api_key
      SOLANA_CLUSTER                = local.solana_cluster
      ENERGY_TOKEN_MINT             = local.env["ENERGY_TOKEN_MINT"]
      # Custodial settlement (Option A): collectors default to the platform payer.
      CURRENCY_TOKEN_MINT      = coalesce(lookup(local.env, "CURRENCY_TOKEN_MINT", ""), "AzFyFd4GkmjqBnJ5EYv7mkaeufAKkZffumjtDRrX425k")
      FEE_COLLECTOR_WALLET     = coalesce(lookup(local.env, "FEE_COLLECTOR_WALLET", ""), "EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ")
      WHEELING_COLLECTOR_WALLET = coalesce(lookup(local.env, "WHEELING_COLLECTOR_WALLET", ""), "EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ")
      LOSS_COLLECTOR_WALLET    = coalesce(lookup(local.env, "LOSS_COLLECTOR_WALLET", ""), "EzudwoHvNPAc4dpPi5ndU8MEZVHVzq3Pj3Thm9ooKmiJ")
      AUTHORITY_WALLET_PATH    = "/app/dev-wallet.json"
      ENABLE_EMAIL_VERIFICATION   = "true"
      EMAIL_VERIFICATION_REQUIRED = "true"
      EMAIL_VERIFICATION_BASE_URL = "http://localhost:4001"
      AES_KEY_BASE64              = local.env["AES_KEY_BASE64"]
      PAYER_PRIVATE_KEY           = local.env["PAYER_PRIVATE_KEY"]
      AGGREGATOR_BRIDGE_PUBLIC_KEY = lookup(local.env, "AGGREGATOR_BRIDGE_PUBLIC_KEY", "")
      # Double-mint guard: aggregator-bridge owns generation issuance.
      ORACLE_MINT_ENABLED      = "false"
      TRADE_SETTLEMENT_ENABLED = "true"
    }
  ) : "${k}=${v}"]

  ports {
    internal = 8092
    external = tonumber(coalesce(lookup(local.env, "TRADING_GRPC_PORT", ""), "5020"))
  }
  ports {
    internal = 8093
    external = tonumber(coalesce(lookup(local.env, "TRADING_HTTP_PORT", ""), "4020"))
  }

  volumes {
    host_path      = "${local.repo_root}/dev-wallet.json"
    container_path = "/app/dev-wallet.json"
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/ca.crt"
    container_path = "/app/infra/certs/ca.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/clients/trading-service-api.crt"
    container_path = "/app/infra/certs/client.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/clients/trading-service-api.key"
    container_path = "/app/infra/certs/client.key"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["trading-service"]
  }

  memory = 1024

  healthcheck {
    test         = ["CMD", "/usr/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8093/health"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 5
    start_period = "15s"
  }
  wait         = true
  wait_timeout = 180

  depends_on = [
    docker_container.pgdog,
    docker_container.redis,
    docker_container.rabbitmq,
    docker_container.iam_service,
    docker_container.chain_bridge,
  ]
}

# Aggregator Bridge + IoT ingestion gateway.
resource "docker_container" "aggregator_bridge" {
  name    = "gridtokenx-aggregator-bridge"
  image   = local.built_image.aggregator_bridge
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [for k, v in merge(
    local.kafka_brokers_env,
    {
      OTEL_EXPORTER_OTLP_ENDPOINT = local.otel
      RUST_LOG                    = "debug,librdkafka=warn"
      # Pin so the host port mapping reaches the gRPC ingestion listener.
      GRPC_PORT = "50051"
      # Settlement-mint throughput tuning (pairs with CHAIN_BRIDGE_MINT_CONCURRENCY).
      MINT_INFLIGHT_LIMIT         = coalesce(lookup(local.env, "MINT_INFLIGHT_LIMIT", ""), "128")
      BILLING_FLUSH_INTERVAL_SECS = coalesce(lookup(local.env, "BILLING_FLUSH_INTERVAL_SECS", ""), "5")
      MINT_RETRY_INTERVAL_SECS    = coalesce(lookup(local.env, "MINT_RETRY_INTERVAL_SECS", ""), "5")
      NTP_SERVERS                 = local.ntp_servers
      REDIS_URL                   = "redis://redis:6379"
      # Bound per-zone Redis streams (unbounded growth OOM-crash-looped redis).
      REDIS_STREAM_MAXLEN  = coalesce(lookup(local.env, "REDIS_STREAM_MAXLEN", ""), "10000")
      RABBITMQ_URL         = local.rabbitmq_url
      DATABASE_URL         = local.pg_url
      TRADING_DATABASE_URL = local.pg_url
      API_GATEWAY_URL      = "http://apisix:9080"
      IAM_GRPC_URL         = "http://apisix:9080"
      TRADING_GRPC_URL     = "http://apisix:9080"
      GRIDTOKENX_API_KEYS  = "${local.engineering_api_key},e2e-test-key"
      # HTTP settlement fallback must hit trading directly (apisix jwt-auth 401s it).
      SETTLEMENT_API_URL            = "http://trading-service:8093"
      AGGREGATOR_BRIDGE_SIGNING_KEY = "/app/aggregator-bridge-signing-key.bin"
      NATS_URL                      = "nats://nats:4222"
      KAFKA_BOOTSTRAP_SERVERS       = "kafka-market:9002"
      KAFKA_TOPIC_METER_READINGS    = "meter.readings"
      INFLUXDB_URL                  = "http://aggregator-influxdb:8086"
      INFLUXDB_ORG                  = coalesce(lookup(local.env, "INFLUXDB_ORG", ""), "gridtokenx")
      INFLUXDB_BUCKET               = coalesce(lookup(local.env, "INFLUXDB_BUCKET", ""), "aggregator_telemetry")
      INFLUXDB_TOKEN                = coalesce(lookup(local.env, "AGGREGATOR_INFLUXDB_TOKEN", ""), "aggregator-bridge-dev-token")
      # Path B generation-mint via Chain Bridge (Vault platform_admin signs).
      MINT_VIA_CHAIN_BRIDGE         = "true"
      CHAIN_BRIDGE_URL              = "http://chain-bridge:5040"
      CHAIN_BRIDGE_INSECURE         = local.chain_bridge_insecure
      CHAIN_BRIDGE_CA_CERT          = "/app/infra/certs/ca.crt"
      CHAIN_BRIDGE_CLIENT_CERT      = "/app/infra/certs/client.crt"
      CHAIN_BRIDGE_CLIENT_KEY       = "/app/infra/certs/client.key"
      CHAIN_BRIDGE_TLS_DOMAIN       = "chain-bridge"
      CHAIN_BRIDGE_SERVICE_IDENTITY = "spiffe://gridtokenx.th/prod/aggregator-bridge"
      SOLANA_RPC_URL                = "http://host.docker.internal:8899"
      # Identity client reads IAM_SERVICE_URL (not IAM_GRPC_URL) for GetUserWallet.
      IAM_SERVICE_URL = "http://iam-service:8090"
      # 120s rides out chain-bridge queue wait instead of outbox republish churn.
      AGGREGATOR_MINT_REPLY_TIMEOUT_SECS = coalesce(lookup(local.env, "AGGREGATOR_MINT_REPLY_TIMEOUT_SECS", ""), "120")
      # `${VAR-default}` semantics (default only when unset; empty disables TLS).
      IOT_GATEWAY_TLS_CERT      = lookup(local.env, "IOT_GATEWAY_TLS_CERT", "/app/infra/certs/aggregator-bridge.crt")
      IOT_GATEWAY_TLS_KEY       = lookup(local.env, "IOT_GATEWAY_TLS_KEY", "/app/infra/certs/aggregator-bridge.key")
      IOT_GATEWAY_TLS_CLIENT_CA = lookup(local.env, "IOT_GATEWAY_TLS_CLIENT_CA", "")
      VAULT_ADDR                = "http://vault:8200"
      VAULT_TOKEN               = local.vault_token
      VAULT_METER_KEK_NAME      = coalesce(lookup(local.env, "VAULT_METER_KEK_NAME", ""), "gridtokenx-meter-kek")
      AGGREGATOR_REQUIRE_SECURE = coalesce(lookup(local.env, "AGGREGATOR_REQUIRE_SECURE", ""), "false")
      AGGREGATOR_ENCRYPT_STREAMS = coalesce(lookup(local.env, "AGGREGATOR_ENCRYPT_STREAMS", ""), "false")
      # Mirror disseminated readings into Postgres meter_readings (dashboard reads).
      AGGREGATOR_PG_READINGS = coalesce(lookup(local.env, "AGGREGATOR_PG_READINGS", ""), "true")
    }
  ) : "${k}=${v}"]

  ports {
    internal = 4010
    external = tonumber(coalesce(lookup(local.env, "IOT_GATEWAY_PORT", ""), "4030"))
  }
  ports {
    internal = 50051
    external = tonumber(coalesce(lookup(local.env, "GRPC_PORT", ""), "50051"))
  }

  volumes {
    host_path      = "${local.repo_root}/infra/aggregator-bridge/signing-key.bin"
    container_path = "/app/aggregator-bridge-signing-key.bin"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/ca.crt"
    container_path = "/app/infra/certs/ca.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/clients/aggregator-bridge.crt"
    container_path = "/app/infra/certs/client.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/clients/aggregator-bridge.key"
    container_path = "/app/infra/certs/client.key"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/aggregator-bridge.crt"
    container_path = "/app/infra/certs/aggregator-bridge.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/aggregator-bridge.key"
    container_path = "/app/infra/certs/aggregator-bridge.key"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["aggregator-bridge"]
  }
  networks_advanced {
    name = docker_network.edge_tier.name
  }

  memory = 768

  healthcheck {
    # :4010 is HTTPS (self-signed) — TCP liveness probe (see compose comment).
    test         = ["CMD", "/usr/bin/busybox", "sh", "-c", "/usr/bin/busybox nc -w 3 127.0.0.1 4010 </dev/null"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 5
    start_period = "15s"
  }
  wait         = true
  wait_timeout = 120

  depends_on = [
    docker_container.redis,
    docker_container.rabbitmq,
    docker_container.nats,
    docker_container.kafka, # compose gates on kafka-market; waiting all three is harmless
    docker_container.aggregator_influxdb,
  ]
}

resource "docker_container" "noti_service" {
  name    = "gridtokenx-noti-service"
  image   = local.built_image.noti_service
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [for k, v in merge(
    local.smtp_env,
    {
      OTEL_EXPORTER_OTLP_ENDPOINT = local.otel
      # Own DB schema (gridtokenx_noti) behind the same PgDog pooler.
      DATABASE_URL           = "postgres://gridtokenx_user:gridtokenx_password@pgdog:6432/gridtokenx_noti"
      MIGRATION_DATABASE_URL = "postgres://gridtokenx_user:gridtokenx_password@pgdog:6432/gridtokenx_noti_migrate"
      REDIS_URL              = "redis://redis:6379"
      KAFKA_BROKERS          = "kafka-cmd:9001"
      RABBITMQ_URL           = local.rabbitmq_url
      PORT                   = "8080"
      RUST_LOG               = "debug"
      JWT_SECRET             = local.env["JWT_SECRET"]
      EMAIL_FROM_NAME        = "GridTokenX"
      NTP_SERVERS            = local.ntp_servers
      EMAIL_FROM_ADDRESS     = "noreply@gridtokenx.com"
      # Email links must be reachable from the recipient's browser (trading UI host port).
      FRONTEND_URL = coalesce(
        lookup(local.env, "FRONTEND_URL", ""),
        "http://localhost:${coalesce(lookup(local.env, "TRADING_UI_PORT", ""), "11001")}"
      )
      CERT_FILE = "/app/infra/certs/server.crt"
      KEY_FILE  = "/app/infra/certs/server.key"
    }
  ) : "${k}=${v}"]

  ports {
    internal = 8080
    external = tonumber(coalesce(lookup(local.env, "NOTI_HTTP_PORT", ""), "4060"))
  }
  ports {
    internal = 8090
    external = tonumber(coalesce(lookup(local.env, "NOTI_GRPC_PORT", ""), "5060"))
  }

  volumes {
    host_path      = "${local.repo_root}/infra/certs/server.crt"
    container_path = "/app/infra/certs/server.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/server.key"
    container_path = "/app/infra/certs/server.key"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["noti-service"]
  }

  memory = 512

  healthcheck {
    test         = ["CMD", "/usr/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/health"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 3
    start_period = "15s"
  }
  wait = true

  depends_on = [
    docker_container.pgdog,
    docker_container.rabbitmq,
    docker_container.redis,
  ]
}
