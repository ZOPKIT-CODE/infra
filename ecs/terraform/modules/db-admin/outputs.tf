output "task_definition_family" {
  description = "Family to pass to `aws ecs run-task --task-definition`. Null when disabled."
  value       = one(aws_ecs_task_definition.db_admin[*].family)
}

output "log_group_name" {
  description = "CloudWatch group the one-off runs log to. Null when disabled."
  value       = one(aws_cloudwatch_log_group.db_admin[*].name)
}
