terraform {
  backend "s3" {
    bucket         = "roboshop-tfstate-123456789012"
    key            = "production/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "roboshop-tf-locks"
    encrypt        = true
  }
}
