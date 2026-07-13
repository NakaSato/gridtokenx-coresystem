# Registry images, pinned (mirrors docker-compose.yml pins).

locals {
  pulled_images = {
    postgres          = "postgres:17-alpine"
    pgdog             = "ghcr.io/pgdogdev/pgdog:main" # upstream publishes no release tags
    redis             = "redis:7-alpine"
    kafka             = "apache/kafka:3.7.0"
    rabbitmq          = "rabbitmq:3.13-management-alpine"
    nats              = "nats:2.10-alpine"
    apisix            = "apache/apisix:3.15.0-debian"
    influxdb          = "influxdb:2.7"
    mailpit           = "axllent/mailpit:v1.30.2"
    prometheus        = "prom/prometheus:v2.50.1"
    postgres_exporter = "prometheuscommunity/postgres-exporter:v0.19.1"
    redis_exporter    = "oliver006/redis_exporter:v1.86.0"
    kafka_exporter    = "danielqsj/kafka-exporter:v1.9.0"
    node_exporter     = "prom/node-exporter:v1.11.1"
    cadvisor          = "gcr.io/cadvisor/cadvisor:v0.55.1"
    grafana           = "grafana/grafana:11.5.0"
    loki              = "grafana/loki:3.4.2"
    alloy             = "grafana/alloy:v1.9.1"
    tempo             = "grafana/tempo:2.7.2"
    vault             = "hashicorp/vault:1.15"
  }
}

resource "docker_image" "pulled" {
  for_each     = local.pulled_images
  name         = each.value
  keep_locally = true
}
