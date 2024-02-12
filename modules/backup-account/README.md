# `backup-account` module
Terraform module that creates all of the resources associated with the Central Backup account and automation framework for managing AWS Backup policies at-scale.

### Types of resources created:
- [KMS keys](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key)
    - KMS key policies and associated resources
- [S3 bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket)
    - Bucket policy, block public access, versioning, encryption, Lambda permissions
- [IAM roles](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role)
    - IAM policies and attachments
- [SQS FIFO queue](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue)
    - Queue policy, Lambda permissions
- [Lambda functions](https://www.google.com/search?client=firefox-b-1-e&q=aws+lambda+function+terraform)
- [CloudWatch Log Groups](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group)
- [Backup vault](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault)
    - Backup vault policy, Backup vault notifications
- [SNS topic](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic)
    - SNS topic, SNS topic policy

## Core Parameters

There are three crucial parameters that are used to set resource and policy access for necessary resources, either for creating resources or constructing ARNs that are needed. These should be configured in the root `variables.tf` or passed as explicitly defined values from the root module's `main.tf`

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | -------- |
| backup_account_id | The 12-digit AWS Account ID for the Central Backup account | `string` | | yes |
| org_id | The ID of your AWS Organizations org | `string` | | yes |

Below you will find the additional variables configurable in this module's `variables.tf`

**NOTE** for parameters with a **Required** value of 'yes' need you to provide a value. If the value is 'no' it simply means that a default is configured where the module should be able to apply and it is optional to configure a different value.

| Name | Description | Type | Default | Required |
| ---- | ------------|------|---------|----------|
| central_vault_name | The name assigned to the central backup vault | `string` | backup-terraform-centralvault | no |
| backup_operator_role_name | Name of the IAM role for backup operations | `string` | BackupOperatorRole | no |
| restore_operator_role_name | Name of the IAM role for restore operations | `string` | RestoreOperatorRole| no |
| enable_key_rotation | Enables automation rotation of the KMS key | `bool` | true | no |
| key_deletion_window_in_days | The wait period if a KMS key is scheduled for deletion | `string` | 30 | no |
| policy_bucket_name | `S3 bucket name for the backup policy |string` | | yes |
| automation_kms_key_alias | The KMS key created in the Central Backup account to encrypt resources for this solution (such as S3 and SQS) | `string` | no |
| s3_lambda_timeout | The time in seconds the S3PolicyMapper Lambda function has to run before timing out | `number` | 60 | no |
| s3_lambda_name | The name that should be given to the S3PolicyMapper function | `string` | S3PolicyMapper | no |
| s3_lambda_description | Description that should be given to the Lambda function | `string` |Uses S3 object changes as a trigger to parse and map backup policies, sending relevant data to a SQS FIFO queue | no |
| s3_lambda_handler | The name of the source code / function as the entry point for Lambda. <mark>DO NOT MODIFY UNLESS YOU ALSO MODIFY THE CORRESPONDING FILE IN THE ROOT MODULE IN THE `python` DIRECTORY | `string` | S3PolicyMapper.lambda_handler | no |
| s3_lambda_source | The source directory in the repo for the Lambda function code (in .zip format). <mark>DO NOT MODIFY UNLESS YOU ALSO MODIFY THE CORRESPONDING FILE IN THE ROOT MODULE IN THE `python` | `string` | `./python/S3PolicyMapper.zip` | no |
| s3_lambda_retry_count | Sets an environment variable for how many times the Lambda should try reprocessing on an unsuccessful attempt. This can also be changed via the Lambda environment variables in AWS | `string` | 3 | no |
| s3_lambda_sleep_time | The time in seconds that should be allowed between retries | `string` | 5 | no |
| org_policy_lambda_timeout | The time in seconds the OrgBackupPolicyManager Lambda function ahs to run before timing out | `number` | 120 | no |
| org_policy_lambda_name | The name of that should be given to the OrgBackupPolicyManager function | `string` | OrgBackupPolicyManager | no | 
| org_policy_lambda_description | Description that should be given to the Lambda function | `string` | Uses SQS as a trigger and creates or modifies/deletes backup policies based on file contents in S3 | no |
| org_policy_lambda_handler | The name of the source code / function as the entry point for Lambda. <mark>DO NOT MODIFY UNLESS YOU ALSO MODIFY THE CORRESPONDING FILE IN THE ROOT MODULE IN THE `python` DIRECTORY | `string` | OrgBackupPolicyManager.lambda_handler | no |
| org_policy_lambda_source | The source directory in the repo for the Lambda function code (in .zip format). <mark>DO NOT MODIFY UNLESS YOU ALSO MODIFY THE CORRESPONDING FILE IN THE ROOT MODULE IN THE `python` | `string` | `./python/OrgBackupPolicyManager.zip` | no |
| org_policy_lambda_retry_count | Sets an environment variable for how many times the Lambda should try reprocessing on an unsuccessful attempt. This can also be changed via the Lambda environment variables in AWS | `string` | 3 | no |
| org_policy_lambda_sleep_time | The time in seconds that should be allowed between retries | `string` | 10 | no |
| lambda_runtime | The Pythong version that should be used with Lambda | `string` | python3.9 | no |
| memory_size | The amount of memory in MB to allocate to your Lambda functions | `number` | 128 | no
policy_definition_file_name | The name of the `.json` backup policy file | `string` | policy_definition.json | no |
| target_list_file_name | The name of the `.json` target list of OUs and accounts | `string` | target_list.json | no |
| backup_policy_description | The description added to backup policies created by this automation framework | `string` | Policy created by Terraform Backup Centralization | no |
| log_retention_days | The number of days CloudWatch Logs should be kept for the function | `number` | 14 | no |
| sqs_queue_name | The name assigned to the FIFO SQS queue. Note that this should end in '.fifo' | `string` | BackupPolicyQ.fifo | no |
| tags | User defined tag keys and values to apply to resources | `map(string)` | [ "backup-terraform" : "enabled" ] | no |
| central_key_alias | The display name of the KMS key. The name must start with the word `alias` followed by a forward slash (alias/). | `string` | alias/TFCentralVaultKey | no |
| notification_topic_name | The name of the SNS topic to send notifications about the central Backup Vault | `string` | Terraform-Backup-Topic | no |

You can also choose to modify the example `.tfvars` file located in `/module-tfvars/backup-account.tfvars` and pass the values via Terraform CLI.

## Use of `Condition` statements in resources
For some resources, such as the `central_backup_vault`, we want to be able to allow multiple accounts access to the resource for things like AWS Backup copy jobs (`backup:CopyIntoBackupVault` operation) to create a secondary copy of recovery points in the Central Backup account. 

To accomplish this for the entire organization, but still restricting open access, we use a condition to only allow members of our organization to perform these operations.

Example:
```
"Condition": {
    "StringEquals": {
        "aws:PrincipalOrgID": "${var.org_id}"
    }
}
```

We are also allowing the Principals to be a wildcard ('*') value so that the only restriction is being a member of the organization. 

This is intended to be an example for ease of implementation and testing, but it is always recommended to restrict your `Principals` and `Resources` to specific roles, ARNs, etc. whenever possible.

If you are only managing a small set of AWS accounts, it may be better to explicitly provide the accounts access than to leave it open to the entire organization.