variable "name_prefix" {
  description = "Resource name prefix, \"<project>-<environment>\"."
  type        = string
}

variable "project" {
  description = "Project name. Scopes the SSM deployed-tag and IAM wildcards."
  type        = string
}

variable "account_id" {
  description = "AWS account ID, used to build ARNs in the trust and permission policies."
  type        = string
}

variable "aws_region" {
  description = "Primary region, used to scope the SSM parameter ARNs."
  type        = string
}

variable "enable_ci_oidc" {
  description = "Create the GitHub OIDC provider and the deploy/infra-apply roles. These are ACCOUNT-level singletons — enable in exactly ONE workspace."
  type        = bool
  default     = false
}

variable "github_deploy_repos" {
  description = "GitHub repos (\"owner/repo\") allowed to assume the deploy role via OIDC."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Common tags applied to the roles and the OIDC provider."
  type        = map(string)
  default     = {}
}
