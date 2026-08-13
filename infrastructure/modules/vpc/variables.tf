variable "project" {
  description = "Project name, used as a name prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, production)."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread subnets over."
  type        = list(string)
}

variable "subnet_newbits" {
  description = "Bits added to the VPC prefix when carving subnets (4 => /20 out of /16)."
  type        = number
  default     = 4
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway (cheap, dev) instead of one per AZ."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Send rejected-traffic VPC flow logs to CloudWatch."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
