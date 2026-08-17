variable "project" {
  description = "Project prefix."
  type        = string
  default     = "roboshop"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.10.0.0/16"
}

variable "availability_zones" {
  description = "Availability Zones used by this environment."
  type        = list(string)

  default = [
    "ap-south-1a",
    "ap-south-1b",
    "ap-south-1c"
  ]
}

variable "kubernetes_version" {
  description = "Amazon EKS Kubernetes version."
  type        = string
  default     = "1.35"
}

variable "app_namespace" {
  description = "Namespace where Roboshop workloads are deployed."
  type        = string
  default     = "roboshop-dev"
}

variable "services" {
  description = "List of ECR repositories to create."
  type        = list(string)

  default = [
    "frontend",
    "catalogue",
    "cart",
    "user",
    "payment",
    "shipping",
    "mongodb",
    "mysql",
    "redis",
    "rabbitmq"
  ]
}

variable "github_org" {
  description = "GitHub organization or username."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
}

variable "github_org_id" {
  description = "Immutable GitHub owner ID for OIDC subject claims."
  type        = string
  default     = ""
}

variable "github_repo_id" {
  description = "Immutable GitHub repository ID for OIDC subject claims."
  type        = string
  default     = ""
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider (only once per AWS account)."
  type        = bool
  default     = true
}

variable "argocd_domain" {
  description = "DNS hostname for the ArgoCD server."
  type        = string
  default     = "argocd.streanzo.online"
}

###############################################################################
# EKS API Access
###############################################################################

variable "public_access_cidrs" {
  description = "CIDRs allowed to access the EKS public API endpoint."
  type        = list(string)

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Do not expose the EKS API to 0.0.0.0/0; use a narrow administrator/runner CIDR."
  }
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
