output "state_bucket_name" {
  description = "Name of the state bucket."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  description = "KMS key that encrypts the state. Principals running Terraform need kms:Encrypt, kms:Decrypt and kms:GenerateDataKey on it."
  value       = aws_kms_key.state.arn
}

output "backend_config" {
  description = "Contents for envs/<env>/backend.hcl."
  value       = <<-EOT
    bucket = "${aws_s3_bucket.state.id}"
    region = "${var.region}"
  EOT
}
