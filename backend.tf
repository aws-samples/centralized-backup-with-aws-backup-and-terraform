# sets the Terraform backend to initialize with state stored in S3 and lock state in DynamoDB
terraform {
  backend "s3" {
    encrypt              = true
    bucket               = "terraform-backup-bucket"
    workspace_key_prefix = "terraform-backup-automation"
    key                  = "terraform-backup-automation/terraform.tfstate"
    dynamodb_table       = "terraform-state-lock"
    region               = "eu-central-1"
  }
}