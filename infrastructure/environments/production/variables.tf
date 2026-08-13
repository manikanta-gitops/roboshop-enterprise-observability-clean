variable "project" {
  description = "Project prefix."
  type        = string
  default     = "roboshop"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "AZs used by this environment."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "kubernetes_version" {
  description = "EKS version."
  type        = string
  default     = "1.35"
}

variable "app_namespace" {
  description = "Namespace the Roboshop workloads run in."
  type        = string
  default     = "roboshop-production"
}

variable "services" {
  description = "Services that get an ECR repository."
  type        = list(string)
  default     = ["cart", "catalogue", "user", "payment", "shipping", "frontend", "mongodb", "mysql"]
}

variable "github_org" {
  description = "GitHub organisation."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository."
  type        = string
}

variable "source_ecr_region" {
  description = "Region containing the CI/dev ECR repositories used as the immutable release source."
  type        = string
  default     = "ap-south-1"
}

variable "endpoint_public_access" {
  description = "Expose the API server publicly. Production should remain private and use a VPC-connected Terraform runner."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API server endpoint."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Production EKS API must never be open to 0.0.0.0/0."
  }
}

variable "argocd_domain" {
  description = "Hostname for the ArgoCD server."
  type        = string
  default     = "argocd.example.com"
}

variable "monthly_budget_usd" {
  description = "Optional AWS monthly cost budget. Set to 0 to disable."
  type        = number
  default     = 0

  validation {
    condition     = var.monthly_budget_usd >= 0
    error_message = "monthly_budget_usd must be zero or positive."
  }
}

variable "budget_email" {
  description = "Email address for AWS Budget notifications. Leave empty when budgets are disabled."
  type        = string
  default     = ""
}
