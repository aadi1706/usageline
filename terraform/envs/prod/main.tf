locals {
  name = "${var.project}-${var.environment}"
}

module "vpc" {
  source = "../../modules/vpc"

  name                    = local.name
  cidr_block              = var.vpc_cidr
  azs                     = var.azs
  enable_nat_gateway      = true
  single_nat_gateway      = false # one NAT per AZ so losing an AZ does not cut off the other
  kubernetes_cluster_name = local.name
}

module "ecr" {
  source = "../../modules/ecr"

  name = local.name
}

module "sqs" {
  source = "../../modules/sqs"

  name = "${local.name}-usage-events"
}

module "eks" {
  source = "../../modules/eks"

  name                = local.name
  subnet_ids          = module.vpc.private_subnet_ids
  public_access_cidrs = var.eks_public_access_cidrs
  node_min_size       = 2
  node_desired_size   = 2
  node_max_size       = 4
}

module "rds" {
  source = "../../modules/rds"

  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.eks.cluster_security_group_id]
  multi_az                   = true
  backup_retention_period    = 7
  deletion_protection        = true
  skip_final_snapshot        = false
}

module "iam" {
  source = "../../modules/iam"

  name              = local.name
  create_irsa_role  = true
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  queue_arn         = module.sqs.queue_arn
  db_secret_arn     = module.rds.master_user_secret_arn
}
