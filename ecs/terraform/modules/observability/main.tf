resource "aws_cloudwatch_log_group" "service" {
  for_each = var.services

  name              = "/ecs/${var.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-${each.key}-logs"
    Service = each.key
    App     = each.value.app
  })
}

resource "aws_sns_topic" "ops_alarms" {
  name = "${var.name_prefix}-ops-alarms"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ops-alarms"
  })
}

resource "aws_sns_topic_subscription" "ops_alarms_email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.ops_alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
