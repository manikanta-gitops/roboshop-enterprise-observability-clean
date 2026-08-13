variable "project" {
  description = "Project name prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, production)."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  description = "VPC to run the cluster in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for worker nodes."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets for internet-facing load balancers."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint."

  type = list(string)

  # Set this in terraform.tfvars
  # Example:
  # public_access_cidrs = ["YOUR_PUBLIC_IP/32"]
}

variable "control_plane_log_types" {
  description = "Control plane log types shipped to CloudWatch."

  type = list(string)

  default = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]
}

variable "control_plane_log_retention_days" {
  description = "CloudWatch retention for control plane logs."
  type        = number
  default     = 30
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)

  default = [
    "t3.large"
  ]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"
}

variable "node_disk_size" {
  description = "Root volume size (GiB) per node."
  type        = number
  default     = 50
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 4
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
