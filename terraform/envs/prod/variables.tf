variable "project" {
  description = "Project name used as a prefix for resource names."
  type        = string
  default     = "usageline"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "prod"
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
  default     = "10.1.0.0/16"
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. No default on purpose: choose them explicitly."
  type        = list(string)
}
