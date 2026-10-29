output "config_file" {
  description = "Path of the configuration file the circuit writes on each host."
  value       = "/etc/keycloak/keycloak.conf"
}

output "url" {
  description = "URL the circuit reaches Keycloak on, from each host itself."
  value       = local.url
}

output "health_url" {
  description = "Readiness URL on the management port, from each host itself."
  value       = local.ready_url
}
