variable "name" {
  description = "Cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Check the currently supported versions before applying."
  type        = string
  default     = "1.33"
}

variable "subnet_ids" {
  description = "Subnets for the control plane network interfaces and the worker nodes (use private subnets)."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API endpoint publicly (restricted to public_access_cidrs)."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint. Must be explicit; 0.0.0.0/0 is rejected."
  type        = list(string)

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Do not open the Kubernetes API to the whole internet; list specific CIDRs."
  }
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"
}

variable "node_min_size" {
  description = "Minimum nodes."
  type        = number
  default     = 1
}

variable "node_desired_size" {
  description = "Initial desired nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum nodes."
  type        = number
  default     = 3
}

variable "node_disk_size_gb" {
  description = "Root volume size per node (gp3, encrypted)."
  type        = number
  default     = 20
}

variable "cluster_log_types" {
  description = "Control plane log types sent to CloudWatch."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "log_retention_days" {
  description = "Retention of the control plane log group."
  type        = number
  default     = 365
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
