variable "project" {
  description = "Project name used as a prefix for resource names."
  type        = string
  default     = "usageline"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "azs" {
  description = "Two availability zones in the region."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "vpc_cidr" {
  description = "CIDR of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway. Off by default in dev because it bills by the hour."
  type        = bool
  default     = false
}

variable "enable_eks" {
  description = "Create the EKS cluster. Off by default in dev: the control plane alone bills by the hour, and nodes in private subnets need the NAT gateway to join."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_eks || var.enable_nat_gateway
    error_message = "enable_eks requires enable_nat_gateway = true: worker nodes live in private subnets and need outbound internet access to register and pull images."
  }
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint (required when enable_eks is true)."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_eks || length(var.eks_public_access_cidrs) > 0
    error_message = "Set eks_public_access_cidrs to your own IP range when enable_eks is true."
  }
}
