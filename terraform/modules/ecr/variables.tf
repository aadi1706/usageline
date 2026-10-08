variable "name" {
  description = "Repository name."
  type        = string
}

variable "image_tag_mutability" {
  description = "IMMUTABLE stops a tag being overwritten, so a tag always means the same image."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["IMMUTABLE", "MUTABLE"], var.image_tag_mutability)
    error_message = "Must be IMMUTABLE or MUTABLE."
  }
}

variable "scan_on_push" {
  description = "Scan every pushed image for known vulnerabilities."
  type        = bool
  default     = true
}

variable "max_tagged_images" {
  description = "Number of most recent images to keep."
  type        = number
  default     = 20
}

variable "untagged_expiry_days" {
  description = "Delete untagged images after this many days."
  type        = number
  default     = 7
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for encryption. Null uses the AWS-managed aws/ecr key."
  type        = string
  default     = null
}

variable "force_delete" {
  description = "Allow deleting the repository even if it still contains images (dev only)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
