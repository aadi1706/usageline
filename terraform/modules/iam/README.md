# iam

The application's **IRSA role**: an IAM role that only the `usageline` Kubernetes service account in the `usageline` namespace can assume (the trust policy checks both the `sub` and `aud` claims of the cluster's OIDC token).

Its permissions are limited to:
- `sqs:SendMessage`, `ReceiveMessage`, `DeleteMessage`, `GetQueueAttributes` on the one usage-events queue;
- `secretsmanager:GetSecretValue` and `DescribeSecret` on the one database secret.

No wildcard actions or resources. Set `create_irsa_role = false` when there is no cluster (for example the dev environment with EKS off). Other roles live next to what they serve: the cluster/node roles in `eks`, flow-log role in `vpc`, monitoring role in `rds`.
