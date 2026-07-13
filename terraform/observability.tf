# Observability: Prometheus + exporters + Grafana + Loki/Alloy + Tempo.
# CPU caps (cpu_period/cpu_quota) mirror compose `cpus:` — the obs stack
# previously pegged the VM and starved app services (stale mints -> DLQ).

resource "docker_container" "prometheus" {
  name    = "gridtokenx-prometheus"
  image   = docker_image.pulled["prometheus"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  command = [
    "--config.file=/etc/prometheus/prometheus.yml",
    "--storage.tsdb.path=/prometheus",
    "--web.console.libraries=/usr/share/prometheus/console_libraries",
    "--web.console.templates=/usr/share/prometheus/consoles",
    "--web.enable-lifecycle",
    "--enable-feature=remote-write-receiver",
  ]

  ports {
    internal = 9090
    external = tonumber(coalesce(lookup(local.env, "PROMETHEUS_PORT", ""), "6001"))
  }

  volumes {
    volume_name    = docker_volume.this["prometheus_data"].name
    container_path = "/prometheus"
  }
  volumes {
    host_path      = "${local.repo_root}/docker/prometheus/prometheus.yml"
    container_path = "/etc/prometheus/prometheus.yml"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/monitoring"
    container_path = "/etc/prometheus/rules"
    read_only      = true
  }
  # mTLS client identity for scraping the aggregator-bridge /metrics gateway
  # (reporting-service = read-only observer cert).
  volumes {
    host_path      = "${local.repo_root}/infra/certs/ca.crt"
    container_path = "/etc/prometheus/certs/ca.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/clients/reporting-service.crt"
    container_path = "/etc/prometheus/certs/client.crt"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/infra/certs/clients/reporting-service.key"
    container_path = "/etc/prometheus/certs/client.key"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["prometheus"]
  }

  cpu_period = 100000
  cpu_quota  = 100000 # 1.0 CPU
  memory     = 768

  healthcheck {
    test         = ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:9090/-/healthy"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 3
    start_period = "15s"
  }
  wait = true
}

resource "docker_container" "postgres_exporter" {
  name    = "gridtokenx-postgres-exporter"
  image   = docker_image.pulled["postgres_exporter"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "DATA_SOURCE_NAME=postgresql://${local.env["POSTGRES_USER"]}:${local.env["POSTGRES_PASSWORD"]}@pgdog:6432/${local.env["POSTGRES_DB"]}?sslmode=disable",
  ]

  ports {
    internal = 9187
    external = tonumber(coalesce(lookup(local.env, "POSTGRES_EXPORTER_PORT", ""), "9187"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["postgres-exporter"]
  }

  memory = 128

  depends_on = [docker_container.pgdog]
}

resource "docker_container" "redis_exporter" {
  name    = "gridtokenx-redis-exporter"
  image   = docker_image.pulled["redis_exporter"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = ["REDIS_ADDR=redis://redis:6379"]

  ports {
    internal = 9121
    external = tonumber(coalesce(lookup(local.env, "REDIS_EXPORTER_PORT", ""), "9121"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["redis-exporter"]
  }

  memory = 128

  depends_on = [docker_container.redis]
}

resource "docker_container" "kafka_exporter" {
  name    = "gridtokenx-kafka-exporter"
  image   = docker_image.pulled["kafka_exporter"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  command = [
    "--kafka.server=kafka-cmd:9001",
    "--kafka.server=kafka-market:9002",
    "--kafka.server=kafka-audit:9003",
  ]

  ports {
    internal = 9308
    external = tonumber(coalesce(lookup(local.env, "KAFKA_EXPORTER_PORT", ""), "9308"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["kafka-exporter"]
  }

  memory = 128

  depends_on = [docker_container.kafka]
}

resource "docker_container" "node_exporter" {
  name    = "gridtokenx-node-exporter"
  image   = docker_image.pulled["node_exporter"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  command = [
    "--path.rootfs=/host",
    "--path.procfs=/host/proc",
    "--path.sysfs=/host/sys",
  ]

  pid_mode = "host"

  volumes {
    host_path      = "/proc"
    container_path = "/host/proc"
    read_only      = true
  }
  volumes {
    host_path      = "/sys"
    container_path = "/host/sys"
    read_only      = true
  }
  volumes {
    host_path      = "/"
    container_path = "/host"
    read_only      = true
  }

  ports {
    internal = 9100
    external = tonumber(coalesce(lookup(local.env, "NODE_EXPORTER_PORT", ""), "9100"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["node-exporter"]
  }

  memory = 128
}

resource "docker_container" "cadvisor" {
  name    = "gridtokenx-cadvisor"
  image   = docker_image.pulled["cadvisor"].image_id
  restart = "unless-stopped"
  # no-new-privileges intentionally omitted: cadvisor runs privileged to read
  # host cgroups/devices; the two options are contradictory.
  privileged = true

  devices {
    host_path = "/dev/kmsg"
  }

  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
    read_only      = true
  }
  volumes {
    host_path      = "/sys"
    container_path = "/sys"
    read_only      = true
  }
  volumes {
    host_path      = "/var/lib/docker"
    container_path = "/var/lib/docker"
    read_only      = true
  }

  ports {
    internal = 8080
    external = tonumber(coalesce(lookup(local.env, "CADVISOR_PORT", ""), "6010"))
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["cadvisor"]
  }

  cpu_period = 100000
  cpu_quota  = 50000 # 0.5 CPU
  memory     = 256
}

resource "docker_container" "grafana" {
  name    = "gridtokenx-grafana"
  image   = docker_image.pulled["grafana"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  env = [
    "GF_SECURITY_ADMIN_USER=${coalesce(lookup(local.env, "GRAFANA_ADMIN_USER", ""), "admin")}",
    "GF_SECURITY_ADMIN_PASSWORD=${coalesce(lookup(local.env, "GRAFANA_ADMIN_PASSWORD", ""), "admin")}",
    "GF_USERS_ALLOW_SIGN_UP=false",
    "GF_SERVER_ROOT_URL=http://localhost:6002",
  ]

  ports {
    internal = 3000
    external = tonumber(coalesce(lookup(local.env, "GRAFANA_PORT", ""), "6002"))
  }

  volumes {
    volume_name    = docker_volume.this["grafana_data"].name
    container_path = "/var/lib/grafana"
  }
  volumes {
    host_path      = "${local.repo_root}/docker/grafana/provisioning/datasources"
    container_path = "/etc/grafana/provisioning/datasources"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/docker/grafana/provisioning/dashboards"
    container_path = "/etc/grafana/provisioning/dashboards"
    read_only      = true
  }
  volumes {
    host_path      = "${local.repo_root}/docker/grafana/dashboards"
    container_path = "/etc/grafana/dashboards"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["grafana"]
  }

  cpu_period = 100000
  cpu_quota  = 75000 # 0.75 CPU
  memory     = 512

  healthcheck {
    test         = ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:3000/api/health"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 3
    start_period = "30s"
  }
  wait = true

  depends_on = [docker_container.prometheus]
}

resource "docker_container" "loki" {
  name    = "gridtokenx-loki"
  image   = docker_image.pulled["loki"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  command = ["-config.file=/etc/loki/loki.yml"]

  ports {
    internal = 3100
    external = tonumber(coalesce(lookup(local.env, "LOKI_PORT", ""), "6003"))
  }

  volumes {
    host_path      = "${local.repo_root}/docker/loki/loki.yml"
    container_path = "/etc/loki/loki.yml"
    read_only      = true
  }
  volumes {
    volume_name    = docker_volume.this["loki_data"].name
    container_path = "/loki"
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["loki"]
  }

  cpu_period = 100000
  cpu_quota  = 75000 # 0.75 CPU
  memory     = 512

  healthcheck {
    test         = ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:3100/ready"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 5
    start_period = "20s"
  }
  wait = true
}

# Alloy — ships container logs to Loki via the Docker socket API.
resource "docker_container" "alloy" {
  name    = "gridtokenx-alloy"
  image   = docker_image.pulled["alloy"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  command = [
    "run",
    "--server.http.listen-addr=0.0.0.0:12345",
    "/etc/alloy/config.alloy",
  ]

  volumes {
    host_path      = "${local.repo_root}/docker/alloy/config.alloy"
    container_path = "/etc/alloy/config.alloy"
    read_only      = true
  }
  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["alloy"]
  }

  cpu_period = 100000
  cpu_quota  = 50000 # 0.5 CPU
  memory     = 256

  depends_on = [docker_container.loki]
}

# Tempo — OTLP tracing backend; remote-writes span metrics to Prometheus.
resource "docker_container" "tempo" {
  name    = "gridtokenx-tempo"
  image   = docker_image.pulled["tempo"].image_id
  restart = "unless-stopped"
  security_opts = ["no-new-privileges:true"]

  command = ["-config.file=/etc/tempo/tempo.yml"]

  ports {
    internal = 3200
    external = tonumber(coalesce(lookup(local.env, "TEMPO_HTTP_PORT", ""), "6004"))
  }

  volumes {
    host_path      = "${local.repo_root}/docker/tempo/tempo.yml"
    container_path = "/etc/tempo/tempo.yml"
    read_only      = true
  }
  volumes {
    volume_name    = docker_volume.this["tempo_data"].name
    container_path = "/var/tempo"
  }

  networks_advanced {
    name    = docker_network.gridtokenx.name
    aliases = ["tempo"]
  }

  cpu_period = 100000
  cpu_quota  = 100000 # 1.0 CPU
  # 512M starved the metrics_generator under sustained span volume.
  memory = 1024

  healthcheck {
    test         = ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:3200/ready"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 5
    start_period = "20s"
  }
  wait = true
}
