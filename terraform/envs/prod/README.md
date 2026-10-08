# envs/prod

Production-shaped environment: one NAT gateway per AZ, EKS with 2 to 4 nodes, RDS Multi-AZ with deletion protection and a final snapshot. `eks_public_access_cidrs` has no default; you must choose who can reach the Kubernetes API.

This folder has only ever been `fmt`-ed and `validate`-d. It has never been planned or applied.
