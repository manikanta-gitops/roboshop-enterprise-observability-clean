variable "region" {
  description = "AWS region that holds the Terraform state."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used for tagging."
  type        = string
  default     = "roboshop"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string
}

variable "lock_table_name" {
  description = "DynamoDB table used for Terraform state locking."
  type        = string
  default     = "roboshop-tf-locks"
}
