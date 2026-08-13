###############################################################################
# production environment: 3 AZs, NAT per AZ, on-demand nodes, HA controllers.
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  environment = "production"

  tags = {
    Project     = var.project
    Environment = local.environment
    ManagedBy   = "terraform"
    Owner       = "platform-engineering"
    CostCenter  = "ecommerce"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project            = var.project
  environment        = local.environment
  region             = var.region
  cidr_block         = var.vpc_cidr
  availability_zones = var.availability_zones
  single_nat_gateway = false # one NAT per AZ, no cross-AZ SPOF
  enable_flow_logs   = true
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

  node_instance_types = ["m6i.large", "m5.large"]
  node_capacity_type  = "ON_DEMAND"
  node_desired_size   = 3
  node_min_size       = 3
  node_max_size       = 9

  endpoint_public_access = var.endpoint_public_access
  public_access_cidrs    = var.public_access_cidrs

  control_plane_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  tags                    = local.tags
}

module "ecr" {
  source = "../../modules/ecr"

  namespace            = var.project
  repositories         = var.services
  image_tag_mutability = "IMMUTABLE" # production tags are the git SHA
  keep_last_images     = 50
  pull_principal_arns  = [module.eks.node_role_arn]
  tags                 = local.tags
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  region        = var.region
  github_org    = var.github_org
  github_repo   = var.github_repo
  role_name     = "${var.project}-${local.environment}-github-actions"
  ecr_namespace = var.project

  # The provider is a per-account singleton; dev created it.
  create_oidc_provider = false

  # Production pushes only happen from main and tags.
  allowed_subjects = [
    "ref:refs/heads/main",
    "ref:refs/tags/*",
    "environment:production",
  ]

  # Release promotion copies the exact image digest built in the dev ECR
  # region into immutable production ECR; no rebuild occurs.
  additional_ecr_read_repository_arns = [
    for service in var.services :
    "arn:aws:ecr:${var.source_ecr_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project}/${service}"
  ]

  tags = local.tags
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
  high_availability = true
  install_argocd    = true
  argocd_domain     = var.argocd_domain
  tags              = local.tags
}

module "backup" {
  source = "../../modules/backup"

  project     = var.project
  environment = local.environment

  # Datastore volumes: nightly for a week, weekly for a month.
  daily_retention_days  = 7
  weekly_retention_days = 30

  # Matches tagSpecification_1 on the production gp3 StorageClass.
  selection_tag_key   = "backup"
  selection_tag_value = "daily"

  tags = local.tags
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
