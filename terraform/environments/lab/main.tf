module "vpc" {
  source = "../../modules/vpc"

  cluster_name = var.cluster_name

  # All other vars use module defaults
  # Override only what differs from defaults
  tags = {
    Phase = "1-vpc"
  }
}


module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  aws_region         = var.aws_region
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  vpc_cidr           = module.vpc.vpc_cidr
  oidc_provider_arn = module.karpenter.oidc_provider_arn
  oidc_provider_url = module.karpenter.oidc_provider_url


  tags = { Phase = "2-eks" }
}

module "karpenter" {
  source = "../../modules/karpenter"
  cluster_name            = var.cluster_name
  cluster_endpoint        = module.eks.cluster_endpoint
  cluster_oidc_issuer_url = module.eks.cluster_oidc_issuer_url
  node_role_arn           = module.eks.node_role_arn
  node_security_group_id  = module.eks.node_security_group_id
  private_subnet_ids      = module.vpc.private_subnet_ids

  tags = { Phase = "3-karpenter" }
}