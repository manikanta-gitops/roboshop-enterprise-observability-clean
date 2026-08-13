variable "project" {
  description = "Project prefix."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "vpc_id" {
  description = "VPC id (needed by the load balancer controller)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "Cluster OIDC provider ARN."
  type        = string
}

variable "oidc_provider_url" {
  description = "Cluster OIDC issuer URL without https://."
  type        = string
}

variable "app_namespace" {
  description = "Namespace the Roboshop workloads run in."
  type        = string
}

variable "secrets_prefix" {
  description = "Secrets Manager / SSM prefix External Secrets may read."
  type        = string
  default     = "roboshop/"
}

variable "high_availability" {
  description = "Run two replicas of each platform controller."
  type        = bool
  default     = false
}

variable "install_argocd" {
  description = "Install ArgoCD into this cluster."
  type        = bool
  default     = true
}

variable "argocd_domain" {
  description = "Hostname used by the ArgoCD server."
  type        = string
  default     = "argocd.example.com"
}

variable "alb_controller_chart_version" {
  description = "aws-load-balancer-controller chart version."
  type        = string
  default     = "3.3.0"
}

variable "external_secrets_chart_version" {
  description = "external-secrets chart version."
  type        = string
  default     = "2.7.0"
}

variable "metrics_server_chart_version" {
  description = "metrics-server chart version."
  type        = string
  default     = "3.13.1"
}

variable "argocd_chart_version" {
  description = "argo-cd chart version."
  type        = string
  default     = "10.2.0"
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}

variable "cluster_autoscaler_chart_version" {
  description = "cluster-autoscaler chart version."
  type        = string
  default     = "9.57.0"
}
