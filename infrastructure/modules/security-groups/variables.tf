variable "project" {
  description = "Project prefix."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "vpc_id" {
  description = "VPC id."
  type        = string
}

variable "ingress_cidrs" {
  description = "CIDRs allowed to reach the public ALB."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "create_datastore_sg" {
  description = "Create a security group for managed datastores (RDS/ElastiCache/MQ)."
  type        = bool
  default     = false
}

variable "datastore_ports" {
  description = "Ports opened on the datastore security group."
  type        = list(number)
  default     = [3306, 6379, 27017, 5672]
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}
