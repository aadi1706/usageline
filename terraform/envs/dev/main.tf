locals {
  name = "${var.project}-${var.environment}"
}

module "vpc" {
  source = "../../modules/vpc"

  name                    = local.name
  cidr_block              = var.vpc_cidr
  azs                     = var.azs
  enable_nat_gateway      = var.enable_nat_gateway
  single_nat_gateway      = true
  kubernetes_cluster_name = var.enable_eks ? local.name : null
}

module "ecr" {
  source = "../../modules/ecr"

  name         = local.name
  force_delete = true # throwaway environment: allow destroy even when images exist
}

module "sqs" {
  source = "../../modules/sqs"

  name = "${local.name}-usage-events"
}

module "eks" {
  source = "../../modules/eks"
  count  = var.enable_eks ? 1 : 0

  name                = local.name
  subnet_ids          = module.vpc.private_subnet_ids
  public_access_cidrs = var.eks_public_access_cidrs
  node_min_size       = 1
  node_desired_size   = 1
  node_max_size       = 2
}

module "rds" {
  source = "../../modules/rds"
  # checkov:skip=CKV_AWS_293:Dev database is throwaway and must be destroyable without a manual step; prod enables deletion protection.
  # checkov:skip=CKV_AWS_157:Multi-AZ doubles the instance cost and dev has no availability requirement; prod runs Multi-AZ.

  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  allowed_security_group_ids = module.eks[*].cluster_security_group_id
  multi_az                   = false
  backup_retention_period    = 1
  deletion_protection        = false
  skip_final_snapshot        = true
}

module "iam" {
  source = "../../modules/iam"

  name              = local.name
  create_irsa_role  = var.enable_eks
  oidc_provider_arn = one(module.eks[*].oidc_provider_arn)
  oidc_provider_url = one(module.eks[*].oidc_provider_url)
  queue_arn         = module.sqs.queue_arn
  db_secret_arn     = module.rds.master_user_secret_arn
}
