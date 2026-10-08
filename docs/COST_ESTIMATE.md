# Monthly cost estimate (ESTIMATE ONLY)

**This is a rough estimate, not a quote.** Nothing in `terraform/` has been planned or applied, so no real bill exists. I did not fetch live AWS pricing: the unit prices below are approximate public list prices (USD) that I am using as assumptions, and prices in `ap-south-1` (Mumbai, the default region) are usually somewhat different from the figures used here. Check the AWS Pricing Calculator before relying on any number. Usage-based charges (data transfer, request volume, log volume) depend on real traffic and are mostly excluded.

Assumes 730 hours per month and the sizes in the Terraform code.

## Unit prices assumed

| Item | Assumed price |
| --- | --- |
| EKS control plane | $0.10/hour = $73.00/month per cluster |
| EC2 `t3.medium` (on-demand) | $0.0416/hour = $30.37/month per node |
| EBS gp3 | $0.08 per GB-month (20 GB per node = $1.60) |
| NAT gateway | $0.045/hour = $32.85/month each, plus $0.045 per GB processed (not included) |
| Public IPv4 address | $0.005/hour = $3.65/month each (one per NAT gateway) |
| RDS PostgreSQL `db.t4g.micro` | $0.016/hour = $11.68/month single-AZ; Multi-AZ is double |
| RDS gp3 storage | $0.115 per GB-month (20 GB = $2.30; Multi-AZ double) |
| KMS customer-managed key | $1.00/month per key |
| Secrets Manager secret | $0.40/month per secret |

## Per environment

| Line item | dev (default: no NAT, no EKS) | dev with NAT + EKS on | prod |
| --- | --- | --- | --- |
| EKS control plane | 0 | $73.00 | $73.00 |
| EKS nodes (EC2 + EBS) | 0 | 1 x $31.97 = $31.97 | 2 x $31.97 = $63.94 |
| NAT gateway + public IP | 0 | 1 x $36.50 = $36.50 | 2 x $36.50 = $73.00 |
| RDS instance | $11.68 | $11.68 | $23.36 (Multi-AZ) |
| RDS storage (20 GB) | $2.30 | $2.30 | $4.60 (Multi-AZ) |
| KMS keys | $1.00 (state bucket key) | $2.00 (+ EKS secrets key) | $2.00 |
| Secrets Manager (DB secret) | $0.40 | $0.40 | $0.40 |
| ECR, SQS, S3 state, VPC, IAM | under $1 | under $1 | under $1 |
| CloudWatch Logs (flow logs, RDS, EKS control plane) | about $1 | about $2 to $4 | about $3 to $6 |
| **Estimated total** | **about $17** | **about $160** | **about $245** |

## What is not included

- NAT data processing ($0.045/GB) and all other data transfer (internet egress, cross-AZ).
- Load balancers: the Terraform does not create any, and a Kubernetes Service of type LoadBalancer or an Ingress would add about $16+/month each.
- Request-based charges (SQS beyond the free tier, Secrets Manager API calls, KMS requests).
- Log volume beyond the small amounts assumed (the EKS control-plane log types are all enabled, which is the main unknown).
- Anything outside this repository (domains, certificates, monitoring SaaS, the GitHub account).

## Where the money goes, and the levers

- **EKS and NAT are about two thirds of the prod bill** and bill by the hour while they exist. That is why dev has both off by default and why a validation rule stops you enabling EKS in dev without NAT.
- The cheapest way to try the cluster is to apply dev with NAT and EKS on, then **destroy it the same day**: it costs roughly $0.22 per hour.
- One shared NAT gateway (`single_nat_gateway = true`) halves the NAT line but loses AZ resilience.
- Spot nodes (`node_capacity_type = "SPOT"`) can cut the node line, at the cost of interruptions.
- Multi-AZ RDS doubles the database line; it is only on in prod.
