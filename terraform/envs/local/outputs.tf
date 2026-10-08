output "kube_prometheus_stack_status" {
  description = "Status of the monitoring release."
  value       = helm_release.kube_prometheus_stack.status
}

output "usageline_status" {
  description = "Status of the application release."
  value       = helm_release.usageline.status
}

output "usageline_hpa_max_replicas" {
  description = "HPA upper bound currently configured."
  value       = var.hpa_max_replicas
}
