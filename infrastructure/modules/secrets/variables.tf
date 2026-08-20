variable "project" {
  description = "Project prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, production)."
  type        = string
}

variable "external_secrets_role_arn" {
  description = "IRSA role ARN used by External Secrets. Granted kms:Decrypt on the app secret key."
  type        = string
}

variable "recovery_window_in_days" {
  description = "Days before a deleted secret is permanently removed."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}