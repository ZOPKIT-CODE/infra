module "observability" {
  source = "./modules/observability"

  name_prefix        = local.name_prefix
  services           = local.services
  log_retention_days = var.log_retention_days
  alarm_email        = var.alarm_email
}

# Address migration: these resources moved from this file into
# ./modules/observability. Without these blocks Terraform reads the new
# addresses as new resources and plans destroy+create. Keep them indefinitely —
# they are also what makes the move land correctly in the `prod` workspace.
moved {
  from = aws_cloudwatch_log_group.service
  to   = module.observability.aws_cloudwatch_log_group.service
}

moved {
  from = aws_sns_topic.ops_alarms
  to   = module.observability.aws_sns_topic.ops_alarms
}

moved {
  from = aws_sns_topic_subscription.ops_alarms_email
  to   = module.observability.aws_sns_topic_subscription.ops_alarms_email
}
