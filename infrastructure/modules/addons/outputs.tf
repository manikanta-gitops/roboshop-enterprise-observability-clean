output "alb_controller_role_arn" {
  description = "IRSA role used by the AWS Load Balancer Controller."
  value       = module.alb_irsa.role_arn
}

output "external_secrets_role_arn" {
  description = "IRSA role used by External Secrets."
  value       = module.external_secrets_irsa.role_arn
}

output "storage_class" {
  description = "Default storage class name."
  value       = kubernetes_storage_class_v1.gp3.metadata[0].name
}
