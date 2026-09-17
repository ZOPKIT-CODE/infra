module "messaging" {
  source = "../messaging"

  name_prefix          = local.name_prefix
  sns_topics           = local.sns_topics
  sqs_queues           = local.sqs_queues
  ops_alarms_topic_arn = module.observability.ops_alarms_topic_arn
}
