variable "region" {
  description = "AWS region holding the ECR repositories."
  type        = string
}

variable "github_org" {
  description = "GitHub organisation or user."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
}

variable "github_org_id" {
  description = "Immutable GitHub owner ID used in OIDC subject claims (immutable subject format). Leave empty for the legacy name-based subject format."
  type        = string
  default     = ""
}

variable "github_repo_id" {
  description = "Immutable GitHub repository ID used in OIDC subject claims (immutable subject format). Leave empty for the legacy name-based subject format."
  type        = string
  default     = ""
}

variable "allowed_subjects" {
  description = "Subject patterns allowed to assume the role."
  type        = list(string)
  default     = ["ref:refs/heads/main", "ref:refs/heads/dev", "environment:dev", "environment:production"]
}

variable "role_name" {
  description = "Name of the CI role."
  type        = string
  default     = "roboshop-github-actions"
}

variable "ecr_namespace" {
  description = "ECR repository prefix the CI role may push to."
  type        = string
  default     = "roboshop"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider when create_oidc_provider is false."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to created resources."
  type        = map(string)
  default     = {}
}

variable "additional_ecr_read_repository_arns" {
  description = "Additional ECR repository ARNs this role may read during artifact promotion."
  type        = list(string)
  default     = []
}

variable "terraform_state_bucket" {
  description = "S3 bucket storing Terraform state the CI role must read/write. Empty to grant no state access."
  type        = string
  default     = ""
}

variable "terraform_state_key" {
  description = "S3 object key (state file) inside terraform_state_bucket. Ignored when terraform_state_bucket is empty."
  type        = string
  default     = ""
}

variable "terraform_lock_table" {
  description = "DynamoDB lock table used by the Terraform backend. Empty to grant no lock table access."
  type        = string
  default     = ""
}

variable "terraform_state_region" {
  description = "AWS region of the Terraform state backend (S3 bucket and DynamoDB lock table). May differ from var.region, which is the application region. Empty to fall back to var.region."
  type        = string
  default     = ""
}
