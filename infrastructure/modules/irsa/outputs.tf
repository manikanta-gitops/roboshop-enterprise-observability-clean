output "role_arn" {
  description = "IAM role ARN to put in the ServiceAccount annotation."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "IAM role name."
  value       = aws_iam_role.this.name
}
