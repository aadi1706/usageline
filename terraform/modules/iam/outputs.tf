output "app_role_arn" {
  description = "ARN of the application IRSA role, or null if it was not created. Annotate the Kubernetes service account with it (eks.amazonaws.com/role-arn)."
  value       = one(aws_iam_role.app[*].arn)
}

output "app_role_name" {
  description = "Name of the application IRSA role, or null if it was not created."
  value       = one(aws_iam_role.app[*].name)
}
