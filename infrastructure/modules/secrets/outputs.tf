# Non-sensitive identifiers only. The secret VALUES are never output; they live
# exclusively in the Terraform state and inside AWS Secrets Manager.
output "secret_name" {
  description = "AWS Secrets Manager secret name (matches the ExternalSecret remoteKey)."
  value       = aws_secretsmanager_secret.app.name
}

output "secret_arn" {
  description = "AWS Secrets Manager secret ARN."
  value       = aws_secretsmanager_secret.app.arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key that encrypts the app secret."
  value       = aws_kms_key.app.arn
}