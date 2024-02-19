terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=4.27.0"
    }
  }
  required_version = ">= 1.3.6"
}

variable "target_account_id" {}
variable "backup_account_id" {}
variable "org_id" {}

resource "aws_kms_key" "local_vault_key" {
  description             = "Key used to encrypt the local backup vault(s) in the member account."
  deletion_window_in_days = var.key_deletion_window_in_days
  enable_key_rotation     = var.enable_key_rotation
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "Allow root user access to all key operations",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : [
            "arn:aws:iam::${var.backup_account_id}:root",
            "arn:aws:iam::${var.target_account_id}:root"
          ]

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
  name          = var.local_key_alias
  target_key_id = aws_kms_key.local_vault_key.key_id
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

# create a backup vault for resources in the target account to back up to
resource "aws_backup_vault" "local_backup_vault" {
  name        = var.local_vault_name
  kms_key_arn = aws_kms_key.local_vault_key.arn
  tags        = var.tags
}

resource "aws_backup_vault_policy" "backup_vault_policy" {
  backup_vault_name = aws_backup_vault.local_backup_vault.name
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
      "Resource" : "${aws_backup_vault.local_backup_vault.arn}"
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
        "Resource" : "${aws_backup_vault.local_backup_vault.arn}"
      }
    ]
  })
  depends_on = [
    aws_iam_role.backup_operator_role,
    aws_iam_role.restore_operator_role,
    aws_backup_vault.local_backup_vault
  ]
}