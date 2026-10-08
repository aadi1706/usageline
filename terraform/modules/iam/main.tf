# Role that only the usageline Kubernetes service account can assume (IRSA).
data "aws_iam_policy_document" "assume" {
  count = var.create_irsa_role ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Both conditions are required: without "sub" any service account in the cluster could assume the role.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  count = var.create_irsa_role ? 1 : 0

  name               = "${var.name}-app"
  assume_role_policy = data.aws_iam_policy_document.assume[0].json

  tags = var.tags
}

# Exact actions on exact resources: no wildcard actions and no wildcard resources.
data "aws_iam_policy_document" "app" {
  count = var.create_irsa_role ? 1 : 0

  statement {
    sid = "UsageEventQueue"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [var.queue_arn]
  }

  statement {
    sid       = "ReadDatabaseCredentials"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "app" {
  count = var.create_irsa_role ? 1 : 0

  name   = "usageline-app"
  role   = aws_iam_role.app[0].id
  policy = data.aws_iam_policy_document.app[0].json
}
