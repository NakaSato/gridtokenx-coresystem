output "user_gateway" {
  description = "APISIX user gateway (HTTP)"
  value       = "http://localhost:4001"
}

output "trading_ui" {
  value = "http://localhost:${coalesce(lookup(local.env, "TRADING_UI_PORT", ""), "11001")}"
}

output "explorer" {
  value = "http://localhost:${coalesce(lookup(local.env, "EXPLORER_PORT", ""), "11002")}"
}

output "grafana" {
  value = "http://localhost:${coalesce(lookup(local.env, "GRAFANA_PORT", ""), "6002")}"
}

output "prometheus" {
  value = "http://localhost:${coalesce(lookup(local.env, "PROMETHEUS_PORT", ""), "6001")}"
}

output "mailpit" {
  value = "http://localhost:${coalesce(lookup(local.env, "MAILPIT_WEB_PORT", ""), "13060")}"
}

output "smartmeter_ui" {
  value = "http://localhost:${coalesce(lookup(local.env, "SMARTMETER_UI_PORT", ""), "12011")}"
}

output "vault" {
  value = "http://localhost:${coalesce(lookup(local.env, "VAULT_PORT", ""), "13001")}"
}
