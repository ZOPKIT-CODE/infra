module "messaging" {
  source = "./modules/messaging"

  name_prefix          = local.name_prefix
  sns_topics           = local.sns_topics
  sqs_queues           = local.sqs_queues
  ops_alarms_topic_arn = module.observability.ops_alarms_topic_arn
}

# Address migration: these resources moved from this file into
# ./modules/messaging. Without these blocks Terraform reads the new addresses as
# new resources and plans destroy+create — which for SQS means losing whatever
# is queued. Keep them indefinitely; they are also what makes the move land
# correctly in the `prod` workspace.
moved {
  from = aws_sns_topic.topics
  to   = module.messaging.aws_sns_topic.topics
}

moved {
  from = aws_sqs_queue.main
  to   = module.messaging.aws_sqs_queue.main
}

moved {
  from = aws_sqs_queue.dlq
  to   = module.messaging.aws_sqs_queue.dlq
}

moved {
  from = aws_sqs_queue_policy.main
  to   = module.messaging.aws_sqs_queue_policy.main
}

moved {
  from = aws_sns_topic_subscription.targeted
  to   = module.messaging.aws_sns_topic_subscription.targeted
}

moved {
  from = aws_sns_topic_subscription.broadcast
  to   = module.messaging.aws_sns_topic_subscription.broadcast
}

moved {
  from = aws_sns_topic_subscription.business
  to   = module.messaging.aws_sns_topic_subscription.business
}

moved {
  from = aws_cloudwatch_metric_alarm.dlq_not_empty
  to   = module.messaging.aws_cloudwatch_metric_alarm.dlq_not_empty
}

moved {
  from = aws_cloudwatch_metric_alarm.accounting_backlog_expiry
  to   = module.messaging.aws_cloudwatch_metric_alarm.accounting_backlog_expiry
}
