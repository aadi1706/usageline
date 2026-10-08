variable "name" {
  description = "Name prefix for the role and policy."
  type        = string
}

variable "create_irsa_role" {
  description = "Create the application IRSA role. Must be known at plan time, so it is a boolean rather than derived from the OIDC ARN."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider."
  type        = string
  default     = null
}

variable "oidc_provider_url" {
  description = "OIDC issuer URL without https://."
  type        = string
  default     = null
}

variable "namespace" {
  description = "Kubernetes namespace of the service account allowed to assume the role."
  type        = string
  default     = "usageline"
}

variable "service_account" {
  description = "Kubernetes service account allowed to assume the role."
  type        = string
  default     = "usageline"
}

variable "queue_arn" {
  description = "ARN of the SQS queue the application may use."
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the database credentials."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
