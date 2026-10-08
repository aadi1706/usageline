variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally unique name of the S3 bucket that stores Terraform state."
  type        = string
}

variable "noncurrent_version_expiration_days" {
  description = "How long old state versions are kept (they allow recovery from a bad apply)."
  type        = number
  default     = 90
}
