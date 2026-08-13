output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "kubeconfig_command" {
  description = "Run this to get cluster credentials."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_registry" {
  description = "Registry host to put in environments/production/global-values.yaml."
  value       = module.ecr.registry_url
}

output "ecr_repository_urls" {
  description = "Per-service ECR repository URLs."
  value       = module.ecr.repository_urls
}

output "github_actions_role_arn" {
  description = "Set as the AWS_OIDC_ROLE_ARN_PROD GitHub secret."
  value       = module.github_oidc.role_arn
}

output "external_secrets_role_arn" {
  description = "IRSA role for External Secrets."
  value       = module.addons.external_secrets_role_arn
}

output "vpc_id" {
  description = "VPC id."
  value       = module.vpc.vpc_id
}

output "backup_vault_name" {
  description = "AWS Backup vault holding datastore EBS recovery points."
  value       = module.backup.vault_name
}
