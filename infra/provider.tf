terraform {
  required_version = ">= 1.0"

  backend "s3" {
    bucket         = "minju-devsecops-tfstate-virginia"
    key            = "devsecops/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-lock-table"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-east-1"
}
