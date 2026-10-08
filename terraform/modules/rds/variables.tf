variable "name" {
  description = "Identifier prefix for the database and its security group."
  type        = string
}

variable "vpc_id" {
  description = "VPC the database lives in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs (at least two AZs) for the DB subnet group."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on 5432 (for example the EKS cluster security group). Empty means nothing can connect."
  type        = list(string)
  default     = []
}

variable "instance_class" {
  description = "Instance size."
  type        = string
  default     = "db.t4g.micro"
}

variable "engine_version" {
  description = "PostgreSQL major version (minor versions are upgraded automatically)."
  type        = string
  default     = "16"
}

variable "allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB (0 disables autoscaling)."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Name of the initial database."
  type        = string
  default     = "usageline"
}

variable "master_username" {
  description = "Master user name. The password is generated and stored by RDS in Secrets Manager."
  type        = string
  default     = "usageline_admin"
}

variable "multi_az" {
  description = "Run a standby replica in a second AZ (doubles the instance cost)."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Days to keep automated backups."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Refuse to delete the database while true."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip the snapshot taken on deletion (acceptable for throwaway dev databases only)."
  type        = bool
  default     = false
}

variable "monitoring_interval" {
  description = "Enhanced monitoring interval in seconds (0 disables it)."
  type        = number
  default     = 60
}

variable "kms_key_id" {
  description = "Customer-managed KMS key for storage and the managed secret. Null uses the AWS-managed keys."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
