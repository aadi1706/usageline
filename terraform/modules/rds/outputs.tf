output "address" {
  description = "DNS name of the database endpoint."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port the database listens on."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Name of the initial database."
  value       = aws_db_instance.this.db_name
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the generated master password."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Security group attached to the database."
  value       = aws_security_group.this.id
}

output "arn" {
  description = "ARN of the DB instance."
  value       = aws_db_instance.this.arn
}
