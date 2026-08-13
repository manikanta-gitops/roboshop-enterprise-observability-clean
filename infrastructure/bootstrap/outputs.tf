output "state_bucket" {
  description = "S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "DynamoDB table used for state locking."
  value       = aws_dynamodb_table.lock.name
}

output "backend_snippet" {
  description = "Copy this into each environment's backend.tf."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.id}"
        key            = "<env>/terraform.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${aws_dynamodb_table.lock.name}"
        encrypt        = true
      }
    }
  EOT
}
