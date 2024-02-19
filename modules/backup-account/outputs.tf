# Name of the bucket
output "s3_backup_policy_repository" {
  description = "The S3 bucket created for storing backup policy definitions and target lists"
  value       = aws_s3_bucket.backup_policy_repository.id
}

# ARN of the KMS key
output "backup_automation_kms_key" {
  description = "The KMS key used to encrypt automation resources in the backup account"
  value       = aws_kms_key.backup_automation_key.arn
}

# ARN of the SQS queue
output "sqs_queue" {
  description = "The name of the SQS queue used to trigger OrgBackupPolicyManager Lambda"
  value       = aws_sqs_queue.fifo_backup_automation_queue.arn
}