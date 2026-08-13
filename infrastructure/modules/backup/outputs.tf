output "vault_name" {
  description = "Backup vault holding the recovery points."
  value       = aws_backup_vault.this.name
}

output "vault_arn" {
  description = "ARN of the backup vault."
  value       = aws_backup_vault.this.arn
}

output "plan_id" {
  description = "ID of the backup plan."
  value       = aws_backup_plan.this.id
}

output "role_arn" {
  description = "IAM role AWS Backup assumes for backup and restore."
  value       = aws_iam_role.this.arn
}
