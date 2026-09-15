variable "name_prefix" {
  description = "Resource name prefix, \"<project>-<environment>\"."
  type        = string
}

variable "enabled" {
  description = "Create the db-admin task definition and its log group. Follows enable_rds — there is nothing to administer without an RDS instance."
  type        = bool
  default     = false
}

variable "aws_region" {
  description = "Region for the awslogs driver."
  type        = string
}

variable "execution_role_arn" {
  description = "Shared ECS execution role (pulls the image, reads the secret, writes logs)."
  type        = string
}

variable "rds_master_secret_arn" {
  description = "Secrets Manager ARN holding the RDS master connection; the `url` key is injected as DB_ADMIN_URL."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
