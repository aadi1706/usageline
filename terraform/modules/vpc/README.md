# vpc

A VPC across two availability zones with one public and one private subnet per AZ (/20 each, carved from the VPC CIDR).

- **NAT gateway is optional and off by default** (`enable_nat_gateway = false`) because it costs money for every hour it exists. Without it, private subnets have no internet access. `single_nat_gateway = true` shares one NAT between both AZs (cheaper, not AZ-resilient); set it to `false` for one per AZ.
- Public subnets never auto-assign public IPs; NAT elastic IPs and load balancers get theirs explicitly.
- The default security group is emptied so nothing can accidentally rely on it.
- A free S3 gateway endpoint keeps S3/ECR-layer traffic off the NAT.
- VPC flow logs go to CloudWatch Logs (toggle with `enable_flow_logs`).
- Subnets carry the Kubernetes load-balancer discovery tags; pass `kubernetes_cluster_name` to add the cluster tag.
