terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=4.27.0"
    }
  }
  required_version = ">= 1.3.6"
}

variable "backup_account_id" {}
variable "org_id" {}

resource "aws_kms_key" "central_vault_key" {
  description             = "Key used to encrypt the central backup vault(s) in the Central Backup account."
  deletion_window_in_days = var.key_deletion_window_in_days
  enable_key_rotation     = var.enable_key_rotation
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "All root user access to all key operations",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:aws:iam::${var.backup_account_id}:root"
        },
        "Action" : "kms:*",
        "Resource" : "*"
      },
      {
        "Sid" : "Allow backup/restore operators access to the key",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : [
            aws_iam_role.backup_operator_role.arn,
            aws_iam_role.restore_operator_role.arn
          ]
        },
        "Action" : [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ],
        "Resource" : "*",
        "Condition" : {
          "StringEquals" : {
            "aws:PrincipalOrgID" : "${var.org_id}"
          }
        }
      }
    ]
  })
  tags = var.tags
}

resource "aws_kms_alias" "central_vault_key_alias" {
  name          = var.central_key_alias
  target_key_id = aws_kms_key.central_vault_key.key_id
}

resource "aws_kms_key" "backup_automation_key" {
  description             = "KMS key used to encrypt resources used for backup automation"
  deletion_window_in_days = var.key_deletion_window_in_days
  enable_key_rotation     = var.enable_key_rotation
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "Enable IAM User Permissions",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:aws:iam::${var.backup_account_id}:root"
        },
        "Action" : "kms:*",
        "Resource" : "*"
      },
      {
        "Sid" : "Allow Lambda functions to use the key.",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : [
            "${aws_iam_role.s3_policy_mapper_role.arn}",
            "${aws_iam_role.org_policy_manager_role.arn}"
          ]
        },
        "Action" : [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ],
        "Resource" : "*"
      }
    ]
  })
  tags = var.tags
}

resource "aws_kms_alias" "backup_automation_kms_key_alias" {
  name          = var.automation_kms_key_alias
  target_key_id = aws_kms_key.backup_automation_key.key_id
}

# SQS queue for managing policy creation/modification/deletion details and triggering OrgBackupPolicyManager Lambda
resource "aws_sqs_queue" "fifo_backup_automation_queue" {
  name                        = var.sqs_queue_name
  content_based_deduplication = true
  deduplication_scope         = "messageGroup"
  delay_seconds               = 10
  fifo_queue                  = true
  kms_master_key_id           = aws_kms_alias.backup_automation_kms_key_alias.id
  message_retention_seconds   = 10800
  visibility_timeout_seconds  = 7200
  receive_wait_time_seconds   = 10
  tags                        = var.tags
}

resource "aws_sqs_queue_policy" "fifo_queue_policy" {
  queue_url = aws_sqs_queue.fifo_backup_automation_queue.id

  policy = jsonencode({
    "Version" : "2008-10-17",
    "Statement" : [
      {
        "Sid" : "___Sender_Statement___",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:aws:iam::${var.backup_account_id}:role/${aws_iam_role.s3_policy_mapper_role.id}"
        },
        "Action" : "SQS:SendMessage",
        "Resource" : "${aws_sqs_queue.fifo_backup_automation_queue.arn}"
      },
      {
        "Sid" : "___Receiver_Statement___",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:aws:iam::${var.backup_account_id}:role/${aws_iam_role.org_policy_manager_role.id}"
        },
        "Action" : [
          "SQS:ReceiveMessage",
          "SQS:DeleteMessage",
          "SQS:ChangeMessageVisibility"
        ],
        "Resource" : "${aws_sqs_queue.fifo_backup_automation_queue.arn}"
      },
      {
        "Sid" : "DenyUnsecureTransport",
        "Effect" : "Deny",
        "Principal" : {
          "AWS" : "*"
        }
        "Action" : "SQS:*",
        "Resource" : "${aws_sqs_queue.fifo_backup_automation_queue.arn}"
        "Condition" : {
          "Bool" : {
            "aws:SecureTransport" : "false"
          }
        }
      }
    ]
  })
  depends_on = [
    aws_iam_role.s3_policy_mapper_role,
    aws_iam_role.org_policy_manager_role
  ]
}

# S3 bucket for storing uploaded backup policies and target lists
resource "aws_s3_bucket" "backup_policy_repository" {
  bucket = var.policy_bucket_name
  tags   = var.tags
  depends_on = [
    aws_kms_key.backup_automation_key
  ]
}

# enable versioning on the S3 bucket
resource "aws_s3_bucket_versioning" "backup_policy_repository" {
  bucket = aws_s3_bucket.backup_policy_repository.id
  versioning_configuration {
    status = "Enabled"
  }
}

# enable encryption with a KMS Customer Managed Key (CMK)
resource "aws_s3_bucket_server_side_encryption_configuration" "bucket_encryption" {
  bucket = aws_s3_bucket.backup_policy_repository.bucket

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_alias.backup_automation_kms_key_alias.id
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "s3_block_public" {
  bucket                  = aws_s3_bucket.backup_policy_repository.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "backup_policy_repository_policy" {
  bucket = aws_s3_bucket.backup_policy_repository.id
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "AllowLambdaBucketAccess",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : [
            "${aws_iam_role.s3_policy_mapper_role.arn}",
            "${aws_iam_role.org_policy_manager_role.arn}"
          ]
        },
        "Action" : [
          "s3:GetBucketAcl",
          "s3:ListBucket"
        ],
        "Resource" : "${aws_s3_bucket.backup_policy_repository.arn}"
      },
      {
        "Sid" : "AllowLambdaObjectActions",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : [
            "${aws_iam_role.s3_policy_mapper_role.arn}",
            "${aws_iam_role.org_policy_manager_role.arn}"
          ]
        },
        "Action" : [
          "s3:GetObject*",
          "s3:PutObject*",
          "s3:DeleteObject*"
        ],
        "Resource" : "${aws_s3_bucket.backup_policy_repository.arn}/*"
      }
    ]
  })
}

resource "aws_s3_bucket_ownership_controls" "bucket_ownership" {
  bucket = aws_s3_bucket.backup_policy_repository.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# creates the Lambda trigger for .zip file upload
resource "aws_s3_bucket_notification" "create_object" {
  bucket = aws_s3_bucket.backup_policy_repository.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_policy_mapper.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".zip"
  }

  # creates the Lambda trigger for file deletion
  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_policy_mapper.arn
    events              = ["s3:ObjectRemoved:*"]
  }
}

resource "aws_lambda_permission" "allow_bucket" {
  statement_id   = "AllowExecutionFromS3Bucket"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.s3_policy_mapper.arn
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.backup_policy_repository.arn
  source_account = var.backup_account_id
}

resource "aws_lambda_permission" "allow_sqs" {
  statement_id   = "AllowExecutionFromSQS"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.org_policy_manager.arn
  principal      = "sqs.amazonaws.com"
  source_arn     = aws_sqs_queue.fifo_backup_automation_queue.arn
  source_account = var.backup_account_id
}

resource "aws_lambda_function" "s3_policy_mapper" {
  filename      = var.s3_lambda_source
  function_name = var.s3_lambda_name
  description   = var.s3_lambda_description
  role          = aws_iam_role.s3_policy_mapper_role.arn
  timeout       = var.s3_lambda_timeout
  handler       = var.s3_lambda_handler
  runtime       = var.lambda_runtime
  memory_size   = var.memory_size
  tags          = var.tags

  # set environmental variable defaults for the function
  environment {
    variables = {
      SQS_QUEUE_URL      = aws_sqs_queue.fifo_backup_automation_queue.url
      RETRY_COUNT        = var.s3_lambda_retry_count
      SLEEP_TIME_SECONDS = var.s3_lambda_sleep_time
    }
  }
}

resource "aws_lambda_function" "org_policy_manager" {
  filename      = var.org_policy_lambda_source
  function_name = var.org_policy_lambda_name
  description   = var.org_policy_lambda_description
  role          = aws_iam_role.org_policy_manager_role.arn
  timeout       = var.org_policy_lambda_timeout
  handler       = var.org_policy_lambda_handler
  runtime       = var.lambda_runtime
  memory_size   = var.memory_size
  tags          = var.tags

  # set environmental variable defaults for the function
  environment {
    variables = {
      POLICY_DEFINITION_FILE_NAME = var.policy_definition_file_name
      TARGET_LIST_FILE_NAME       = var.target_list_file_name
      BACKUP_POLICY_DESCRIPTION   = var.backup_policy_description
      SQS_QUEUE_URL               = aws_sqs_queue.fifo_backup_automation_queue.url
      RETRY_COUNT                 = var.org_policy_lambda_retry_count
      SLEEP_TIME_SECONDS          = var.org_policy_lambda_sleep_time
    }
  }
}

resource "aws_lambda_event_source_mapping" "sqs_message_event" {
  event_source_arn = aws_sqs_queue.fifo_backup_automation_queue.arn
  function_name    = aws_lambda_function.org_policy_manager.arn
  enabled          = true
  batch_size       = 1
}

# CloudWatch Log group for S3PolicyMapper Lambda function
resource "aws_cloudwatch_log_group" "s3_policy_mapper_log_group" {
  name              = "/aws/lambda/${var.s3_lambda_name}"
  retention_in_days = var.log_retention_days
}

# CloudWatch Log group for OrgBackupPolicyManager Lambda function
resource "aws_cloudwatch_log_group" "org_policy_manager_log_group" {
  name              = "/aws/lambda/${var.org_policy_lambda_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role_policy_attachment" "s3_policy_mapper_role_attachment" {
  role       = aws_iam_role.s3_policy_mapper_role.id
  policy_arn = aws_iam_policy.s3_policy_mapper_policy.arn
}

resource "aws_iam_policy" "s3_policy_mapper_policy" {

  name        = "${var.s3_lambda_name}Policy"
  path        = "/"
  description = "IAM policy for the S3PolicyMapper Lambda function"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Condition" : {
          "StringEquals" : {
            "aws:SourceAccount" : "${var.backup_account_id}"
          }
        },
        "Action" : [
          "logs:CreateLogStream",
          "logs:Describelog_groups",
          "logs:PutLogEvents"
        ],
        "Resource" : [
          "${aws_cloudwatch_log_group.s3_policy_mapper_log_group.arn}"
        ],
        "Effect" : "Allow"
      }
    ]
  })
  tags = var.tags
}

resource "aws_iam_role" "s3_policy_mapper_role" {
  name = "${var.s3_lambda_name}Role"
  path = "/"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "",
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "lambda.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
  description           = "IAM role for S3PolicyMapper Lambda function."
  force_detach_policies = false
  max_session_duration  = 3600
  tags                  = var.tags
}

resource "aws_iam_role_policy_attachment" "s3_policy_mapper_attachment" {
  role       = aws_iam_role.s3_policy_mapper_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "org_policy_manager_role_attachment" {
  role       = aws_iam_role.org_policy_manager_role.id
  policy_arn = aws_iam_policy.org_policy_manager_policy.arn
}

resource "aws_iam_policy" "org_policy_manager_policy" {
  name        = "${var.org_policy_lambda_name}Policy"
  path        = "/"
  description = "IAM policy for the OrgBackupPolicyManager Lambda function"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Condition" : {
          "StringEquals" : {
            "aws:SourceAccount" : "${var.backup_account_id}"
          }
        },
        "Action" : [
          "logs:CreateLogStream",
          "logs:DescribeLogGroups",
          "logs:PutLogEvents"
        ],
        "Resource" : [
          "${aws_lambda_function.org_policy_manager.arn}"
        ],
        "Effect" : "Allow"
      },
      {
        "Action" : [
          "sqs:DeleteMessage",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
          "sqs:GetQueueAttributes"
        ],
        "Resource" : "${aws_sqs_queue.fifo_backup_automation_queue.arn}",
        "Effect" : "Allow"
      },
      {
        "Condition" : {
          "StringEquals" : {
            "aws:PrincipalOrgID" : "${var.org_id}"
          }
        },
        "Action" : [
          "organizations:ListPoliciesForTarget",
          "organizations:ListTargetsForPolicy",
          "organizations:CreatePolicy",
          "organizations:UpdatePolicy",
          "organizations:AttachPolicy",
          "organizations:DetachPolicy",
          "organizations:DeletePolicy",
          "organizations:ListPolicies",
          "organizations:DescribePolicy",
          "organizations:DescribeEffectivePolicy"
        ],
        "Resource" : "*",
        "Effect" : "Allow"
      }
    ]
  })
  tags = var.tags
}

resource "aws_iam_role" "org_policy_manager_role" {
  name = "${var.org_policy_lambda_name}Role"
  path = "/"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "",
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "lambda.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
  description           = "IAM role for OrgBackupPolicyManager Lambda function."
  force_detach_policies = false
  max_session_duration  = 3600
  tags                  = var.tags
}

resource "aws_iam_role_policy_attachment" "org_policy_manager_attachment" {
  role       = aws_iam_role.org_policy_manager_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# create a backup vault for resources in the target account to back up to
resource "aws_backup_vault" "central_backup_vault" {
  name        = var.central_vault_name
  kms_key_arn = aws_kms_key.central_vault_key.arn
  tags        = var.tags
}

resource "aws_backup_vault_policy" "backup_vault_policy" {
  backup_vault_name = aws_backup_vault.central_backup_vault.name
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [{
      "Sid" : "Allow backup operator actions",
      "Effect" : "Allow",
      "Principal" : {
        "AWS" : "${aws_iam_role.backup_operator_role.arn}"
      },
      "Action" : [
        "backup:DescribeBackupVault",
        "backup:GetBackupVaultAccessPolicy",
        "backup:ListRecoveryPointsByBackupVault",
        "backup:StartBackupJob"
      ],
      "Resource" : "${aws_backup_vault.central_backup_vault.arn}"
      },
      {
        "Sid" : "Allow restore operator actions",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "${aws_iam_role.restore_operator_role.arn}"
        },
        "Action" : [
          "backup:DescribeBackupVault",
          "backup:GetBackupVaultAccessPolicy",
          "backup:ListRecoveryPointsByBackupVault",
          "backup:StartRestoreJob"
        ],
        "Resource" : "${aws_backup_vault.central_backup_vault.arn}"
      },
      {
        "Sid" : "Allow backup copy by org members",
        "Effect" : "Allow",
        "Principal" : "*",
        "Action" : [
          "backup:CopyIntoBackupVault"
        ],
        "Resource" : "${aws_backup_vault.central_backup_vault.arn}"
        "Condition" : {
          "StringEquals" : {
            "aws:PrincipalOrgID" : "${var.org_id}"
          }
        }
      }
    ]
  })
  depends_on = [
    aws_iam_role.backup_operator_role,
    aws_iam_role.restore_operator_role,
    aws_backup_vault.central_backup_vault
  ]

}

# create the IAM role with the necessary role policy for performing backup operations that a user can assume
resource "aws_iam_role" "backup_operator_role" {
  name = var.backup_operator_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "backup.amazonaws.com"
        }
      },
    ]
  })
  tags = var.tags
}

# attach the managed policy for backup operator role
resource "aws_iam_role_policy_attachment" "aws_managed_backup_operator" {
  role       = aws_iam_role.backup_operator_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# create the IAM role with the necessary role policy for performing restore operations that a user can assume
resource "aws_iam_role" "restore_operator_role" {
  name = var.restore_operator_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "backup.amazonaws.com"
        }
      },
    ]
  })
  tags = var.tags
}

# attach the managed policy for restore operator role
resource "aws_iam_role_policy_attachment" "aws_managed_restore_operator" {
  role       = aws_iam_role.restore_operator_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# Backup SNS topic
resource "aws_sns_topic" "backup_sns_topic" {
  name              = var.notification_topic_name
  kms_master_key_id = aws_kms_alias.backup_automation_kms_key_alias.id
}

resource "aws_sns_topic_policy" "default" {
  arn = aws_sns_topic.backup_sns_topic.arn

  policy = jsonencode({
    "Version" : "2008-10-17",
    "Id" : "__default_policy_ID",
    "Statement" : [
      {
        "Sid" : "__default_statement_ID",
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "backup.amazonaws.com"
        },
        "Action" : [
          "SNS:Publish"
        ],
        "Resource" : "${aws_sns_topic.backup_sns_topic.arn}"
      }
    ]
  })
}

# send backup notifications when job starts to the created SNS topic
resource "aws_backup_vault_notifications" "backup_notification_on_start" {
  backup_vault_name   = var.central_vault_name
  sns_topic_arn       = aws_sns_topic.backup_sns_topic.arn
  backup_vault_events = ["BACKUP_JOB_STARTED"]
}