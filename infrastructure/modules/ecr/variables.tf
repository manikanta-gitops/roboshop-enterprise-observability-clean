variable "namespace" {
  description = "Repository name prefix, e.g. roboshop."
  type        = string
}

variable "repositories" {
  description = "Service names to create repositories for."
  type        = list(string)
}

variable "image_tag_mutability" {
  description = "MUTABLE or IMMUTABLE. Immutable is recommended for production."
  type        = string
  default     = "IMMUTABLE"
}

variable "force_delete" {
  description = "Allow terraform destroy to delete repositories that still hold images."
  type        = bool
  default     = false
}

variable "keep_last_images" {
  description = "How many tagged release images to keep."
  type        = number
  default     = 30
}

variable "release_tag_prefixes" {
  description = "Tag prefixes treated as releases by the lifecycle policy."
  type        = list(string)
  default     = ["main", "dev", "v"]
}

variable "untagged_expire_days" {
  description = "Days before untagged images expire."
  type        = number
  default     = 7
}

variable "pull_principal_arns" {
  description = "Extra IAM principals allowed to pull (e.g. the EKS node role)."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every repository."
  type        = map(string)
  default     = {}
}

