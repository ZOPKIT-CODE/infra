output "topic_arns" {
  description = "Topic key -> SNS topic ARN."
  value       = { for k, t in aws_sns_topic.topics : k => t.arn }
}

output "queue_urls" {
  description = "Queue key -> SQS queue URL."
  value       = { for k, q in aws_sqs_queue.main : k => q.url }
}

output "queue_arns" {
  description = "Queue key -> SQS queue ARN."
  value       = { for k, q in aws_sqs_queue.main : k => q.arn }
}

output "dlq_urls" {
  description = "Queue key -> dead-letter queue URL (only keys with dlq = true)."
  value       = { for k, q in aws_sqs_queue.dlq : k => q.url }
}

output "dlq_arns" {
  description = "Queue key -> dead-letter queue ARN (only keys with dlq = true)."
  value       = { for k, q in aws_sqs_queue.dlq : k => q.arn }
}
