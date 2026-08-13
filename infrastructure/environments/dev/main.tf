###############################################################################
# dev environment: cheap but structurally identical to production.
###############################################################################

locals {
  environment = "dev"

  tags = {
    Project     = var.project
    Environment = local.environment
    ManagedBy   = "terraform"
    Owner       = "platform-engineering"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project            = var.project
  environment        = local.environment
  region             = var.region
  cidr_block         = var.vpc_cidr
  availability_zones = var.availability_zones
  single_nat_gateway = true # one NAT keeps dev under ~$35/month
  enable_flow_logs   = false
  tags               = local.tags
}

module "security_groups" {
  source = "../../modules/security-groups"

  project     = var.project
  environment = local.environment
  vpc_id      = module.vpc.vpc_id
  tags        = local.tags
}

module "eks" {
  source = "../../modules/eks"

  project            = var.project
  environment        = local.environment
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  # EKS API Access
  endpoint_public_access = true
  public_access_cidrs    = var.public_access_cidrs

  # Managed Node Group
  node_instance_types =  ["c7i-flex.large"]
  node_capacity_type  = "ON_DEMAND"
  node_desired_size   = 1
  node_min_size       = 1
  node_max_size       = 2

  # Control Plane Logs
  control_plane_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  tags = local.tags
}

module "ecr" {
  source = "../../modules/ecr"

  namespace            = var.project
  repositories         = var.services
  image_tag_mutability = "IMMUTABLE" # commit SHA tags are never overwritten; no mutable dev release tag
  keep_last_images     = 15
  # Chart repositories are published once, from the production account stack.
  pull_principal_arns  = [module.eks.node_role_arn]
  tags                 = local.tags
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  region               = var.region
  github_org           = var.github_org
  github_repo          = var.github_repo
  role_name            = "${var.project}-${local.environment}-github-actions"
  ecr_namespace        = var.project
  create_oidc_provider = var.create_github_oidc_provider
  tags                 = local.tags
}

module "addons" {
  source = "../../modules/addons"

  project           = var.project
  environment       = local.environment
  cluster_name      = module.eks.cluster_name
  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  app_namespace     = var.app_namespace
  secrets_prefix    = "${var.project}/${local.environment}/"
  high_availability = false
  install_argocd    = true
  argocd_domain     = var.argocd_domain
  tags              = local.tags
}

resource "aws_budgets_budget" "monthly" {
  count = var.monthly_budget_usd > 0 && var.budget_email != "" ? 1 : 0

  name         = "${var.project}-${local.environment}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
