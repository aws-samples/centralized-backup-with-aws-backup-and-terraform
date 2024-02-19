variable "local_vault_name" {
  description = "The name of the member backup account local vault"
  type        = string
  default     = "backup-terraform-localvault"
}

variable "backup_operator_role_name" {
  description = "The name of the IAM role that should be used for backup operations"
  type        = string
  default     = "BackupOperatorRole"
}

variable "restore_operator_role_name" {
  description = "The name of the IAM role that should be used for restore operations"
  type        = string
  default     = "RestoreOperatorRole"
}

variable "tags" {
  description = "Tags that should be applied to reosurces"
  type        = map(string)
  default = {
    backup-terraform = "enabled"
  }
}

variable "enable_key_rotation" {
  description = "Specifies whether key rotation is enabled"
  type        = bool
  default     = true
}

variable "key_deletion_window_in_days" {
  description = "Duration in days after which the key is deleted after destruction of the resource. Must be between 7 and 30 days."
  type        = string
  default     = 30
}

variable "local_key_alias" {
  description = "The display name of the KMS key. The name must start with the word \"alias\" followed by a forward slash (alias/)."
  type        = string
  default     = "alias/TFLocalVaultKey"
}