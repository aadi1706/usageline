variable "kubeconfig_path" {
  description = "Kubeconfig file that contains the kind-usageline context."
  type        = string
  default     = "~/.kube/config"
}

variable "image_tag" {
  description = "Tag of the usageline image already loaded into kind (scripts/kind-up.sh prints and loads it as usageline:<tag>). Terraform does not build or load images."
  type        = string

  validation {
    condition     = length(var.image_tag) > 0
    error_message = "Set image_tag to the tag of the image loaded into kind."
  }
}

variable "hpa_max_replicas" {
  description = "Upper bound for the API's HorizontalPodAutoscaler."
  type        = number
  default     = 5

  validation {
    condition     = var.hpa_max_replicas >= 2
    error_message = "hpa_max_replicas must be at least 2 (the HPA minimum)."
  }
}

variable "kube_prometheus_stack_version" {
  description = "Pinned kube-prometheus-stack chart version."
  type        = string
  default     = "92.1.0"
}
