output "alb_security_group_id" {
  description = "Security group for internet-facing ALBs."
  value       = aws_security_group.alb.id
}

output "node_extra_security_group_id" {
  description = "Extra security group for worker nodes."
  value       = aws_security_group.node_extra.id
}

output "datastore_security_group_id" {
  description = "Datastore security group id (empty when disabled)."
  value       = try(aws_security_group.datastore[0].id, "")
}
