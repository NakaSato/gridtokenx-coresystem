# Shared locals. The repo's .env is the single source of truth for configuration,
# exactly as it is for docker-compose.yml — parsed here so Terraform and Compose
# read identical values. `coalesce(lookup(...), "d")` mirrors compose `${VAR:-d}`
# (default when unset OR empty); bare `lookup(..., "d")` mirrors `${VAR-d}`
# (default only when unset).
#
# Limitation: .env values must not carry inline `# comments` after the value.

locals {
  repo_root = abspath("${path.module}/..")

  _env_lines = [
    for line in split("\n", file("${local.repo_root}/.env")) :
    trimspace(line)
    if trimspace(line) != "" && !startswith(trimspace(line), "#") && strcontains(line, "=")
  ]
  env = {
    for line in local._env_lines :
    trimspace(split("=", line)[0]) =>
    trim(trimspace(join("=", slice(split("=", line), 1, length(split("=", line))))), "\"'")
  }

  tz          = lookup(local.env, "TZ", "UTC")
  otel        = coalesce(lookup(local.env, "OTEL_EXPORTER_OTLP_ENDPOINT", ""), "http://tempo:4318")
  ntp_servers = coalesce(lookup(local.env, "NTP_SERVERS", ""), "time.cloudflare.com:123,time.google.com:123")

  rabbit_user  = coalesce(lookup(local.env, "RABBITMQ_DEFAULT_USER", ""), "gridtokenx")
  rabbit_pass  = coalesce(lookup(local.env, "RABBITMQ_DEFAULT_PASS", ""), "rabbitmq_secret_2025")
  rabbitmq_url = "amqp://${local.rabbit_user}:${local.rabbit_pass}@rabbitmq:5672"

  # Every service points its DATABASE_URL at pgdog:6432 (sole Postgres pooler).
  pg_url = "postgresql://gridtokenx_user:gridtokenx_password@pgdog:6432/gridtokenx"

  kafka_brokers_env = {
    KAFKA_CMD_BROKERS    = "kafka-cmd:9001"
    KAFKA_MARKET_BROKERS = "kafka-market:9002"
    KAFKA_AUDIT_BROKERS  = "kafka-audit:9003"
  }

  smtp_env = {
    SMTP_HOST     = "mailpit"
    SMTP_PORT     = "1025"
    SMTP_TLS_MODE = "none"
    SMTP_FROM     = "noreply@gridtokenx.com"
  }

  chain_bridge_insecure = coalesce(lookup(local.env, "CHAIN_BRIDGE_INSECURE", ""), "false")

  # mTLS client identity toward Chain Bridge; per-service cert files are bind-
  # mounted to the same in-container paths. SERVICE_IDENTITY set per service.
  chain_bridge_client_env = {
    CHAIN_BRIDGE_URL         = coalesce(lookup(local.env, "CHAIN_BRIDGE_URL", ""), "http://chain-bridge:5040")
    CHAIN_BRIDGE_INSECURE    = local.chain_bridge_insecure
    CHAIN_BRIDGE_CA_CERT     = "/app/infra/certs/ca.crt"
    CHAIN_BRIDGE_CLIENT_CERT = "/app/infra/certs/client.crt"
    CHAIN_BRIDGE_CLIENT_KEY  = "/app/infra/certs/client.key"
    CHAIN_BRIDGE_TLS_DOMAIN  = "chain-bridge"
  }

  solana_program_env = {
    SOLANA_REGISTRY_PROGRAM_ID     = local.env["SOLANA_REGISTRY_PROGRAM_ID"]
    SOLANA_TRADING_PROGRAM_ID      = local.env["SOLANA_TRADING_PROGRAM_ID"]
    SOLANA_ORACLE_PROGRAM_ID       = local.env["SOLANA_ORACLE_PROGRAM_ID"]
    SOLANA_GOVERNANCE_PROGRAM_ID   = local.env["SOLANA_GOVERNANCE_PROGRAM_ID"]
    SOLANA_ENERGY_TOKEN_PROGRAM_ID = local.env["SOLANA_ENERGY_TOKEN_PROGRAM_ID"]
  }

  docker_solana_rpc   = coalesce(lookup(local.env, "DOCKER_SOLANA_RPC_URL", ""), "http://host.docker.internal:8899")
  vault_token         = coalesce(lookup(local.env, "VAULT_TOKEN", ""), "root")
  engineering_api_key = coalesce(lookup(local.env, "ENGINEERING_API_KEY", ""), "engineering-department-api-key-2025")
  solana_cluster      = coalesce(lookup(local.env, "SOLANA_CLUSTER", ""), "localnet")

  # Compose-built application images (docker compose build). Terraform manages
  # runtime only — BuildKit Dockerfiles build poorly through the Docker provider.
  built_image = {
    chain_bridge         = "gridtokenx-coresystem-chain-bridge:latest"
    iam_service          = "gridtokenx-coresystem-iam-service:latest"
    meter_service        = "gridtokenx-coresystem-meter-service:latest"
    trading_service      = "gridtokenx-coresystem-trading-service:latest"
    aggregator_bridge    = "gridtokenx-coresystem-aggregator-bridge:latest"
    noti_service         = "gridtokenx-coresystem-noti-service:latest"
    trading_ui           = "gridtokenx-coresystem-trading-ui:latest"
    explorer             = "gridtokenx-coresystem-explorer:latest"
    smartmeter_simulator = "gridtokenx-coresystem-smartmeter-simulator:latest"
    smartmeter_ui        = "gridtokenx-coresystem-smartmeter-ui:latest"
    openleadr_vtn        = "gridtokenx-coresystem-openleadr-vtn:latest"
  }
}
