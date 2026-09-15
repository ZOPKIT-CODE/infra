variable "name_prefix" {
  description = "Resource name prefix, \"<project>-<environment>\"."
  type        = string
}

variable "services" {
  description = "ECS service contract (local.services). One log group is created per key; each value must carry `app`. Untyped: service entries are not uniform (optional target_group_name / extra_host_headers)."
  type        = any
}

variable "log_retention_days" {
  description = "CloudWatch retention for the per-service log groups."
  type        = number
}

variable "alarm_email" {
  description = "Email subscribed to the ops alarm topic. Empty disables the subscription."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags merged into every resource."
  type        = map(string)
  default     = {}
}
