terraform {
  backend "s3" {
    bucket         = "roboshop-terraform-state-704475327673"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "roboshop-tf-locks"
    encrypt        = true
  }
}
