resource "aws_security_group" "this" {
  name_prefix = "${var.name}-rds-"
  description = "PostgreSQL access for ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-rds" })

  lifecycle {
    create_before_destroy = true
  }
}

# One rule per allowed client security group; no CIDR-based access and no egress rules.
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from allowed client security group"
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids

  tags = var.tags
}

data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json

  tags = var.tags
}

# AWS-managed policy scoped to exactly what enhanced monitoring needs.
resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# TLS-only connections, plus logging of schema changes and any statement slower than 1 second (not every query, to keep log volume and cost low).
resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-"
  family      = "postgres${var.engine_version}"
  description = "TLS-only connections and query logging for ${var.name}"

  # Reject connections that do not use TLS (this is also the default on PostgreSQL 15+, but stated explicitly).
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.master_username
  # RDS generates the master password and keeps it in Secrets Manager (see master_user_secret_arn),
  # so no password ever appears in code or Terraform state.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_id

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage > 0 ? var.max_allocated_storage : null
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_id

  parameter_group_name   = aws_db_parameter_group.this.name
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period    = var.backup_retention_period
  copy_tags_to_snapshot      = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = var.skip_final_snapshot
  final_snapshot_identifier  = var.skip_final_snapshot ? null : "${var.name}-final"
  auto_minor_version_upgrade = true

  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null
  # checkov:skip=CKV_AWS_353:Performance Insights is not enabled to keep cost and data collection minimal on a db.t4g.micro; enhanced monitoring and CloudWatch logs are on.
  # checkov:skip=CKV_AWS_354:Performance Insights is off (see CKV_AWS_353), so there is no PI data to encrypt.

  tags = var.tags
}
