output "log_group_names" {
  description = "Service key -> CloudWatch log group name."
  value       = { for k, g in aws_cloudwatch_log_group.service : k => g.name }
}

output "ops_alarms_topic_arn" {
  description = "SNS topic ARN that CloudWatch alarms publish to."
  value       = aws_sns_topic.ops_alarms.arn
}
