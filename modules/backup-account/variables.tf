variable "central_vault_name" {
  description = "The name of the central backup account vault"
  type        = string
  default     = "backup-terraform-centralvault"
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

variable "policy_bucket_name" {
  description = "The name of the bucket. If omitted, Terraform will assign a random, unique name."
  type        = string
  default     = ""
}

variable "automation_kms_key_alias" {
  description = "The display name of the KMS key. The name must start with the word \"alias\" followed by a forward slash (alias/)."
  type        = string
  default     = "alias/BackupAutomationResources"
}

variable "s3_lambda_timeout" {
  description = "The amount of time (in seconds) your Lambda Function has to run"
  type        = number
  default     = 60
}

variable "s3_lambda_name" {
  description = "A unique name for your Lambda Function"
  type        = string
  default     = "S3PolicyMapper"
}

variable "s3_lambda_description" {
  description = "Description of your Lambda Function (or Layer)"
  type        = string
  default     = "Uses S3 object changes as a trigger to parse and map backup policies, sending relevant data to a SQS FIFO queue"
}

variable "s3_lambda_handler" {
  description = "Lambda Function entrypoint in your code"
  type        = string
  default     = "S3PolicyMapper.lambda_handler"
}

variable "s3_lambda_source" {
  description = "The location of the source code in .zip format"
  type        = string
  default     = "./python/S3PolicyMapper.zip"
}

variable "s3_lambda_retry_count" {
  description = "The number of times an operation should be retried to account for potential concurrent operations, timeouts, etc. It is a value in seconds but must be in string format"
  type        = string
  default     = "3"
}

variable "s3_lambda_sleep_time" {
  description = "The amount of time that the function should sleep between retry operations. It is a value in seconds but must be in string format"
  type        = string
  default     = "5"
}

variable "org_policy_lambda_timeout" {
  description = "The amount of time (in seconds) your Lambda Function has to run"
  type        = number
  default     = 120
}

variable "org_policy_lambda_name" {
  description = "A unique name for your Lambda Function"
  type        = string
  default     = "OrgBackupPolicyManager"
}

variable "org_policy_lambda_description" {
  description = "Description of your Lambda Function (or Layer)"
  type        = string
  default     = "Uses SQS as a trigger and creates or modifies/deletes backup policies based on file contents in S3"
}

variable "org_policy_lambda_handler" {
  description = "Lambda Function entrypoint in your code"
  type        = string
  default     = "OrgBackupPolicyManager.lambda_handler"
}

variable "org_policy_lambda_source" {
  description = "The location of the source code in .zip format"
  type        = string
  default     = "./python/OrgBackupPolicyManager.zip"
}

variable "org_policy_lambda_retry_count" {
  description = "The number of times an operation should be retried to account for potential concurrent operations, timeouts, etc. It is a value in seconds but must be in string format"
  type        = string
  default     = "3"
}

variable "org_policy_lambda_sleep_time" {
  description = "The amount of time that the function should sleep between retry operations. It is a value in seconds but must be in string format"
  type        = string
  default     = "10"
}

variable "lambda_runtime" {
  description = "Lambda Function runtime"
  type        = string
  default     = "python3.11"
}

variable "memory_size" {
  description = "Amount of memory in MB your Lambda Function can use at runtime. Valid value between 128 MB to 10,240 MB (10 GB), in 64 MB increments."
  type        = number
  default     = 128
}

variable "policy_definition_file_name" {
  description = "The name of the backup policy file defined in .json format"
  type        = string
  default     = "policy_definition.json"
}

variable "target_list_file_name" {
  description = "The name of the target OU/account list defined in .json format"
  type        = string
  default     = "target_list.json"
}

variable "backup_policy_description" {
  description = "The description that should be given to an uploaded backup policy"
  type        = string
  default     = "Policy created by Terraform Backup Centralization"
}

variable "log_retention_days" {
  description = "Log retention days for log group"
  type        = number
  default     = 14
}

variable "sqs_queue_name" {
  description = "The name of the SQS queue where backup policy data is sent. Since it is a FIFO queue, it should end with .fifo"
  type        = string
  default     = "BackupPolicyQ.fifo"
}

variable "tags" {
  description = "Tags that should be applied to reosurces"
  type        = map(string)
  default = {
    backup-terraform = "enabled"
  }
}

variable "central_key_alias" {
  description = "The display name of the KMS key. The name must start with the word \"alias\" followed by a forward slash (alias/)."
  type        = string
  default     = "alias/TFCentralVaultKey"
}

variable "notification_topic_name" {
  description = "The name of the SNS topic to send notifications about the central Backup vault"
  type        = string
  default     = "Terraform-Backup-Topic"
}