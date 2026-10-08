# rds

PostgreSQL on `db.t4g.micro` (the smallest Graviton class), encrypted at rest, in private subnets, **not publicly accessible**.

- **No password in code.** `manage_master_user_password = true` makes RDS generate the password and store it in Secrets Manager. Read the secret ARN from the `master_user_secret_arn` output; applications fetch it at runtime (the `iam` module grants a pod read access to exactly that secret).
- **Network:** the only ingress is port 5432 from the security groups you list in `allowed_security_group_ids` (for example the EKS cluster security group). No CIDR rules, no egress rules.
- IAM database authentication, CloudWatch log export, enhanced monitoring, storage autoscaling, automated backups and deletion protection are on by default. `multi_az`, backup retention, deletion protection and the final snapshot are the knobs that differ between dev and prod.
- Performance Insights is deliberately off (justified skip in `main.tf`).
