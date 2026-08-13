terraform {
  backend "s3" {
    bucket         = "roboshop-tfstate-347076821255"
    key            = "dev/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
