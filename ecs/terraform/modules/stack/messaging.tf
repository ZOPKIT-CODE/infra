module "messaging" {
  source = "../messaging"

  name_prefix          = local.name_prefix
  sns_topics           = local.sns_topics
  sqs_queues           = local.sqs_queues
  ops_alarms_topic_arn = module.observability.ops_alarms_topic_arn
}

# ./modules/messaging. Without these blocks Terraform reads the new addresses as
# new resources and plans destroy+create — which for SQS means losing whatever
# is queued. Keep them indefinitely; they are also what makes the move land
# correctly in the `prod` workspace.
