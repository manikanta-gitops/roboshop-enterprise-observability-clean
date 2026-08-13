output "role_arn" {
  description = "ARN to set as the AWS_OIDC_ROLE_ARN GitHub secret."
  value       = aws_iam_role.ci.arn
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN in use."
  value       = local.provider_arn
}
