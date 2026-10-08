# envs/dev

Cheap, throwaway environment. NAT gateway **off** and EKS **off** by default; RDS single-AZ with 1-day backups, no deletion protection, no final snapshot; ECR can be force-deleted.

To try the cluster, set both `enable_nat_gateway = true` and `enable_eks = true` (a validation rule requires NAT whenever EKS is on) and give `eks_public_access_cidrs` your own IP range.

This folder has only ever been `fmt`-ed and `validate`-d. It has never been planned or applied.
