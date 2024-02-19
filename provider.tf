terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=4.27.0"
    }
  }
  required_version = ">= 1.3.6"
}

# provider defintions for member accounts
provider "aws" {
  alias  = "target"
  region = "eu-central-1"
  assume_role {
    role_arn = "arn:aws:iam::${var.target_account_id}:role/OrganizationAccountAccessRole"
  }
}

# provider defintion for the central backup account
provider "aws" {
  alias  = "backup"
  region = "eu-central-1"
  assume_role {
    role_arn = "arn:aws:iam::${var.backup_account_id}:role/OrganizationAccountAccessRole"
  }
}