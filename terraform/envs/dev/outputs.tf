output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "ecr_repository_url" {
  description = "Where to push the API image."
  value       = module.ecr.repository_url
}

output "queue_url" {
  description = "URL of the usage-events queue."
  value       = module.sqs.queue_url
}

output "db_address" {
  description = "PostgreSQL endpoint."
  value       = module.rds.address
}

output "db_secret_arn" {
  description = "Secrets Manager secret with the generated database password."
  value       = module.rds.master_user_secret_arn
}

output "eks_cluster_name" {
  description = "Cluster name, or null when EKS is disabled."
  value       = one(module.eks[*].cluster_name)
}

output "app_role_arn" {
  description = "IRSA role for the application, or null when EKS is disabled."
  value       = module.iam.app_role_arn
}
