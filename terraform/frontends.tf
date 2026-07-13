# Frontends, smart-meter simulator, and the OpenADR VTN test target.

# Trading Platform UI (Next.js).
resource "docker_container" "trading_ui" {
  name    = "gridtokenx-trading"
  image   = local.built_image.trading_ui
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "NODE_ENV=${local.env["NODE_ENV"]}",
    "TZ=${local.tz}",
    "NEXT_PUBLIC_API_URL=${coalesce(lookup(local.env, "NEXT_PUBLIC_API_URL", ""), "http://localhost:4001")}",
    "NEXT_PUBLIC_SOLANA_RPC_URL=${local.env["NEXT_PUBLIC_SOLANA_RPC_URL"]}",
    "NEXT_PUBLIC_API_BASE_URL=${coalesce(lookup(local.env, "NEXT_PUBLIC_API_BASE_URL", ""), "http://localhost:4001")}",
    "NEXT_PUBLIC_PYTH_PRICE_SERVICE_URL=${local.env["NEXT_PUBLIC_PYTH_PRICE_SERVICE_URL"]}",
    "NEXT_PUBLIC_MAPBOX_TOKEN=${local.env["NEXT_PUBLIC_MAPBOX_TOKEN"]}",
  ]

  ports {
    internal = 3000
    external = tonumber(coalesce(lookup(local.env, "TRADING_UI_PORT", ""), "11001"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["trading-ui"]
  }

  memory = 512

  healthcheck {
    test         = ["CMD", "bun", "-e", "fetch('http://localhost:3000').then(r => r.ok ? process.exit(0) : process.exit(1)).catch(() => process.exit(1))"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 3
    start_period = "15s"
  }
  wait = true

  depends_on = [docker_container.iam_service, docker_container.trading_service]
}

# Block Explorer (Next.js) — runtime config injected per request, so RPC /
# program-ID changes only need a container restart, not an image rebuild.
resource "docker_container" "explorer" {
  name    = "gridtokenx-explorer"
  image   = local.built_image.explorer
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "NODE_ENV=${coalesce(lookup(local.env, "NODE_ENV", ""), "production")}",
    "TZ=${local.tz}",
    "SOLANA_RPC_HTTP=${coalesce(lookup(local.env, "NEXT_PUBLIC_SOLANA_RPC_URL", ""), "http://localhost:8899")}",
    "DEFAULT_CLUSTER=${local.solana_cluster}",
    "TRADING_PROGRAM_ID=${lookup(local.env, "SOLANA_TRADING_PROGRAM_ID", "")}",
    "TOKEN_PROGRAM_ID=${lookup(local.env, "SOLANA_ENERGY_TOKEN_PROGRAM_ID", "")}",
    "GOVERNANCE_PROGRAM_ID=${lookup(local.env, "SOLANA_GOVERNANCE_PROGRAM_ID", "")}",
    "ORACLE_PROGRAM_ID=${lookup(local.env, "SOLANA_ORACLE_PROGRAM_ID", "")}",
    "REGISTRY_PROGRAM_ID=${lookup(local.env, "SOLANA_REGISTRY_PROGRAM_ID", "")}",
    "TREASURY_PROGRAM_ID=${lookup(local.env, "SOLANA_TREASURY_PROGRAM_ID", "")}",
    "BLOCKBENCH_PROGRAM_ID=${lookup(local.env, "SOLANA_BLOCKBENCH_PROGRAM_ID", "")}",
  ]

  ports {
    internal = 4000
    external = tonumber(coalesce(lookup(local.env, "EXPLORER_PORT", ""), "11002"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["explorer"]
  }

  memory = 512

  healthcheck {
    test         = ["CMD", "node", "-e", "fetch('http://localhost:4000').then(r => r.ok ? process.exit(0) : process.exit(1)).catch(() => process.exit(1))"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 3
    start_period = "15s"
  }
  wait = true
}

# Smart Meter Simulator (Python/FastAPI). DLMS/COSEM egress to the Aggregator
# Bridge IoT gateway over TLS (dev CA, SAN = aggregator-bridge).
resource "docker_container" "smartmeter_simulator" {
  name    = "gridtokenx-smartmeter-simulator"
  image   = local.built_image.smartmeter_simulator
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [for k, v in {
    TZ                   = local.tz
    PORT                 = "8082"
    LOG_LEVEL            = "INFO"
    PYTHONPATH           = "/app:/app/src"
    AUTOSTART_SIMULATION = "true"
    METRICS_PORT         = "9091"
    # Empty -> engine falls back to TODAY 08:00 UTC; pin only for replay.
    SIMULATION_START_TIME      = lookup(local.env, "SMARTMETER_SIM_START_TIME", "")
    AGGREGATOR_BRIDGE_URL      = "https://aggregator-bridge:4010"
    AGGREGATOR_TLS_CA          = "/app/infra/certs/ca.crt"
    AGGREGATOR_TLS_CLIENT_CERT = coalesce(lookup(local.env, "AGGREGATOR_TLS_CLIENT_CERT", ""), "/app/infra/certs/smartmeter-simulator.crt")
    AGGREGATOR_TLS_CLIENT_KEY  = coalesce(lookup(local.env, "AGGREGATOR_TLS_CLIENT_KEY", ""), "/app/infra/certs/smartmeter-simulator.key")
    AGGREGATOR_DLMS_ENABLED    = coalesce(lookup(local.env, "SMARTMETER_DLMS_ENABLED", ""), "true")
    AGGREGATOR_ENCRYPT_ENABLED = coalesce(lookup(local.env, "SMARTMETER_ENCRYPT_ENABLED", ""), "false")
    AGGREGATOR_KEY_ROTATION_ENABLED    = coalesce(lookup(local.env, "SMARTMETER_KEY_ROTATION_ENABLED", ""), "false")
    AGGREGATOR_KEY_GRACE_VERSIONS      = coalesce(lookup(local.env, "SMARTMETER_KEY_GRACE_VERSIONS", ""), "2")
    AGGREGATOR_KEY_ROTATION_INTERVAL_S = coalesce(lookup(local.env, "SMARTMETER_KEY_ROTATION_INTERVAL_S", ""), "0")
    VAULT_ADDR           = "http://vault:8200"
    VAULT_TOKEN          = local.vault_token
    VAULT_METER_KEK_NAME = coalesce(lookup(local.env, "VAULT_METER_KEK_NAME", ""), "gridtokenx-meter-kek")
    # Must match one of the bridge's GRIDTOKENX_API_KEYS (else 401 on ingest).
    AGGREGATOR_API_KEY = coalesce(lookup(local.env, "SMARTMETER_AGGREGATOR_API_KEY", ""), "engineering-department-api-key-2025")
    REDIS_URL          = "redis://redis:6379"
    IAM_GATEWAY_URL    = "http://apisix:9080"
    AGGREGATOR_IAM_ONBOARD_ENABLED = coalesce(lookup(local.env, "SMARTMETER_IAM_ONBOARD_ENABLED", ""), "false")
    POSTGIS_URL     = local.pg_url
    POSTGIS_ENABLED = coalesce(lookup(local.env, "SMARTMETER_POSTGIS_ENABLED", ""), "false")
  } : "${k}=${v}"]

  ports {
    internal = 8082
    external = tonumber(coalesce(lookup(local.env, "SMARTMETER_PORT", ""), "8082"))
  }

  volumes {
    host_path      = "${local.repo_root}/gridtokenx-smartmeter-simulator/data"
    container_path = "/app/data"
  }
  volumes {
    # Dev hot-reload of the simulator source.
    host_path      = "${local.repo_root}/gridtokenx-smartmeter-simulator/backend/src/smart_meter_simulator"
    container_path = "/app/src/smart_meter_simulator"
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/ca.crt"
    container_path = "/app/infra/certs/ca.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/clients/smartmeter-simulator.crt"
    container_path = "/app/infra/certs/smartmeter-simulator.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/clients/smartmeter-simulator.key"
    container_path = "/app/infra/certs/smartmeter-simulator.key"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["smartmeter-simulator"]
  }

  # CPU cap: uncapped sim firehose pegs the VM and starves kafka-market's raft
  # heartbeat (producer MessageTimedOut flood).
  cpu_period = 100000
  cpu_quota  = 150000 # 1.5 CPUs
  memory     = 512

  healthcheck {
    test         = ["CMD", "curl", "-f", "http://localhost:8082/api/v1/quality/health"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 3
    start_period = "20s"
  }
  wait         = true
  wait_timeout = 120

  depends_on = [
    docker_container.redis,
    docker_container.postgres,
    docker_container.aggregator_bridge,
  ]
}

# Smart Meter Simulator UI (Next.js).
resource "docker_container" "smartmeter_ui" {
  name    = "gridtokenx-smartmeter-ui"
  image   = local.built_image.smartmeter_ui
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "NEXT_PUBLIC_SIMULATOR_URL=http://apisix.gridtokenx-coresystem.orb.local",
    # Server-side rewrite target (next.config rewrites /api -> backend).
    "SIMULATOR_URL=http://smartmeter-simulator:8082",
  ]

  ports {
    internal = 3000
    external = tonumber(coalesce(lookup(local.env, "SMARTMETER_UI_PORT", ""), "12011"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["smartmeter-ui"]
  }

  memory = 384

  healthcheck {
    test     = ["CMD", "node", "-e", "fetch('http://localhost:3000').then(r => r.ok ? process.exit(0) : process.exit(1)).catch(() => process.exit(1))"]
    interval = "30s"
    timeout  = "10s"
    retries  = 3
  }
  wait = true

  depends_on = [docker_container.smartmeter_simulator]
}

# OpenADR 3 VTN (openleadr-rs v0.2.3) — demand-response test target.
resource "docker_container" "openleadr_vtn_db" {
  name    = "gridtokenx-openleadr-vtn-db"
  image   = docker_image.pulled["postgres"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "POSTGRES_USER=openadr",
    "POSTGRES_DB=openadr",
    "POSTGRES_PASSWORD=${coalesce(lookup(local.env, "OPENLEADR_PG_PASSWORD", ""), "openadr")}",
    "TZ=${local.tz}",
  ]

  ports {
    internal = 5432
    external = tonumber(coalesce(lookup(local.env, "OPENLEADR_PG_PORT", ""), "7030"))
  }

  volumes {
    volume_name    = docker_volume.this["openleadr_vtn_db_data"].name
    container_path = "/var/lib/postgresql/data"
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["openleadr-vtn-db"]
  }

  memory = 384

  healthcheck {
    test     = ["CMD-SHELL", "pg_isready -U openadr"]
    interval = "5s"
    timeout  = "5s"
    retries  = 5
  }
  wait = true
}

resource "docker_container" "openleadr_vtn" {
  name    = "gridtokenx-openleadr-vtn"
  image   = local.built_image.openleadr_vtn
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "RUST_LOG=openleadr_vtn=info",
    "OAUTH_TOKEN_URL=http://localhost:3000/auth/token",
    "DATABASE_URL=postgres://openadr:${coalesce(lookup(local.env, "OPENLEADR_PG_PASSWORD", ""), "openadr")}@openleadr-vtn-db:5432/openadr",
  ]

  ports {
    internal = 3000
    external = tonumber(coalesce(lookup(local.env, "OPENLEADR_VTN_PORT", ""), "4031"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["openleadr-vtn"]
  }

  memory = 384

  depends_on = [docker_container.openleadr_vtn_db]
}

# One-shot seeder: waits for VTN migrations, inserts default dev OAuth clients.
resource "docker_container" "openleadr_vtn_seed" {
  name    = "gridtokenx-openleadr-vtn-seed"
  image   = docker_image.pulled["postgres"].image_id
  restart = "no"
  security_opts = ["no-new-privileges:true"]

  # One-shot: exits 0 after seeding; Terraform must not require it running.
  must_run = false

  env = ["PGPASSWORD=${coalesce(lookup(local.env, "OPENLEADR_PG_PASSWORD", ""), "openadr")}"]

  entrypoint = [
    "sh", "-c",
    <<-EOT
      i=0;
      until psql -h openleadr-vtn-db -U openadr -d openadr -c "select 1 from \"user\" limit 1" >/dev/null 2>&1; do
        i=$((i+1));
        if [ $i -ge 60 ]; then echo "VTN migrations never appeared" >&2; exit 1; fi;
        sleep 2;
      done;
      psql -h openleadr-vtn-db -U openadr -d openadr -v ON_ERROR_STOP=1 -f /seed-users.sql
    EOT
  ]

  volumes {
    host_path      = "${local.repo_root}/scripts/openleadr-vtn/seed-users.sql"
    container_path = "/seed-users.sql"
    read_only      = true
  }

  networks_advanced {
    name = docker_network.gridtokenx.name
  }

  depends_on = [docker_container.openleadr_vtn]
}
