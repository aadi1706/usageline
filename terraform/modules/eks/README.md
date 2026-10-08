# eks

An EKS cluster with a small **managed node group** (default 2x `t3.medium`, min 1, max 3, encrypted gp3 disks, IMDSv2 only) and **IRSA** (IAM Roles for Service Accounts).

- **IRSA:** the module creates the cluster's IAM OIDC provider. A pod's Kubernetes service account can then be mapped to a dedicated IAM role (see the `iam` module), so pods get only the AWS permissions they need and never use the node's broad role.
- **API endpoint:** private access is always on; public access is on but restricted to the CIDRs in `public_access_cidrs` (required, and `0.0.0.0/0` is rejected by validation).
- Kubernetes Secrets are envelope-encrypted with a dedicated, rotating KMS key; all five control plane log types go to CloudWatch.
- The node role uses the three AWS-managed policies EKS requires; nothing else is attached.
- **Nodes live in private subnets, so they need outbound internet (NAT) or VPC endpoints to join the cluster and pull images.** The dev environment enforces this: EKS can only be enabled there together with the NAT gateway.
- Not included (documented limits): cluster add-ons management, an autoscaler, and the AWS Load Balancer Controller.
