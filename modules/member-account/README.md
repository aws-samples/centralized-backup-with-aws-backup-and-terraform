# `member-account` module
Terraform module that creates the backup vault for member accounts, as well as `backup_operator_role` and `restore_operator_role` IAM roles.

### Types of resources created:
- [KMS keys](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key)
    - KMS key policies and associated resources
- [IAM roles](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role)
    - IAM policies and attachments
- [Backup vault](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault)
    - Backup vault policy

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
| local_vault_name | The name given to the local backup vault | `string` | backup-terraform-localvault | no |
| backup_operator_role_name | Name of the IAM role for backup operations | `string` | BackupOperatorRole | no |
| restore_operator_role_name | Name of the IAM role for restore operations | `string` | RestoreOperatorRole| no |
| tags | User defined tag keys and values to apply to resources | `map(string)` | [ "backup-terraform" : "enabled" ] | no |
| enable_key_rotation | Specifies whether key rotation is enabled | `bool` | tru | no |
| key_deletion_window_in_days | Duration in days after which the key is deleted after destruction of the resources | string | 30 | no |
| local_key_alias | The display name of the KMS key. The name must start with the word `alias` followed by a forward slash (alias/). | string | alias/TFLocalVaultKey | no |


You can also choose to modify the example `.tfvars` file located in `/module-tfvars/member-account.tfvars` and pass the values via Terraform CLI.