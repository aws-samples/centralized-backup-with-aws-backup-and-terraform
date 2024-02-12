variable "target_account_id" {
  description = "The 12-digit AWS account ID for your target account"
  type        = string
  default     = ""
}

variable "backup_account_id" {
  description = "The 12-digit AWS account ID for the central backup account"
  type        = string
  default     = ""
}

variable "org_id" {
  description = "The ID associated with your organization in AWS Organizations"
  type        = string
  default     = ""
}