output "repository_urls" {
  description = "Map of service name to repository URL."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "registry_url" {
  description = "Registry host shared by all repositories."
  value       = length(var.repositories) > 0 ? split("/", values(aws_ecr_repository.this)[0].repository_url)[0] : ""
}

output "repository_arns" {
  description = "Map of service name to repository ARN."
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}

