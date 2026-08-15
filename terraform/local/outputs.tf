output "fleet_hosts" {
  description = "Container names of the fleet, consumed by the Ansible dynamic inventory."
  value       = docker_container.fleet[*].name
}

output "fleet_size" {
  description = "Number of fleet servers provisioned."
  value       = var.fleet_size
}

output "prometheus_url" {
  description = "Prometheus address used by the pipeline's SLO promotion gate."
  value       = var.monitoring_enabled ? "http://localhost:30090" : null
}

output "grafana_url" {
  description = "Grafana address. Credentials are admin / proofline."
  value       = var.monitoring_enabled ? "http://localhost:30300" : null
}
