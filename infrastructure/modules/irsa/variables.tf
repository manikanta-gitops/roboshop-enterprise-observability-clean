variable "role_name" {
  description = "IAM role name."
  type        = string
}

variable "description" {
  description = "Role description."
  type        = string
  default     = "IRSA role"
}

variable "oidc_provider_arn" {
  description = "Cluster OIDC provider ARN."
  type        = string
}

variable "oidc_provider_url" {
  description = "Cluster OIDC issuer URL without https://."
  type        = string
}

variable "service_accounts" {
  description = "List of namespace:serviceaccount pairs allowed to assume the role."
  type        = list(string)
}

variable "inline_policy_json" {
  description = "Inline policy document JSON. Empty string skips it."
  type        = string
  default     = ""
}

variable "managed_policy_arns" {
  description = "Managed policies to attach."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}
