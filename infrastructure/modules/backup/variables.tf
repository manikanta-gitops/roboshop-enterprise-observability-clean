variable "project" {
  description = "Project name prefix."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev or production."
  type        = string
}

variable "daily_schedule" {
  description = "Cron expression for the daily backup rule."
  type        = string
  default     = "cron(0 1 * * ? *)"
}

variable "daily_retention_days" {
  description = "Days to keep daily recovery points."
  type        = number
  default     = 7
}

variable "weekly_schedule" {
  description = "Cron expression for the weekly backup rule."
  type        = string
  default     = "cron(0 2 ? * SUN *)"
}

variable "weekly_retention_days" {
  description = "Days to keep weekly recovery points. 0 disables the weekly rule."
  type        = number
  default     = 30
}

variable "selection_tag_key" {
  description = "Tag key an EBS volume must carry to be backed up."
  type        = string
  default     = "backup"
}

variable "selection_tag_value" {
  description = "Tag value an EBS volume must carry to be backed up."
  type        = string
  default     = "daily"
}

variable "tags" {
  description = "Tags applied to the vault, plan and role."
  type        = map(string)
  default     = {}
}
