variable "name" {
  description = "Name prefix for all VPC resources."
  type        = string
}

variable "cidr_block" {
  description = "CIDR of the VPC. Subnets are carved out of it as /20 blocks."
  type        = string
}

variable "azs" {
  description = "Exactly two availability zones to spread subnets across."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 2
    error_message = "Exactly two availability zones are required."
  }
}

variable "enable_nat_gateway" {
  description = "Create NAT gateway(s) so private subnets can reach the internet. Costs money while it exists."
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one per AZ (cheaper, but not AZ-resilient)."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention for the flow log group."
  type        = number
  default     = 365
}

variable "kubernetes_cluster_name" {
  description = "If set, subnets are tagged so Kubernetes load balancers can discover them."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
