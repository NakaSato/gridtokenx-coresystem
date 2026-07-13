# Networks + named volumes. Names deliberately match what docker-compose created
# (project prefix "gridtokenx-coresystem_") so switching Compose -> Terraform
# reuses the existing data volumes instead of starting empty.
# NOTE: `tofu destroy` therefore deletes the same data Compose was using.

resource "docker_network" "gridtokenx" {
  name   = "gridtokenx-coresystem_gridtokenx-network"
  driver = "bridge"
}

resource "docker_network" "user_tier" {
  name   = "gridtokenx-coresystem_user-tier"
  driver = "bridge"
}

resource "docker_network" "edge_tier" {
  name   = "gridtokenx-coresystem_edge-tier"
  driver = "bridge"
}

locals {
  volume_keys = [
    "postgres_data",
    "redis_data",
    "mailpit_data",
    "kafka_cmd_data",
    "kafka_market_data",
    "kafka_audit_data",
    "rabbitmq_data",
    "nats_data",
    "prometheus_data",
    "grafana_data",
    "loki_data",
    "tempo_data",
    "openleadr_vtn_db_data",
    "iam_ows_vault",
    "aggregator-influxdb-data",
    "aggregator-influxdb-config",
  ]
}

resource "docker_volume" "this" {
  for_each = toset(local.volume_keys)
  name     = "gridtokenx-coresystem_${each.key}"
}
