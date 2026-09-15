# CloudWatch log groups + the ops alarm SNS topic.
#
# Groups are created here rather than left to the awslogs driver's auto-create so
# the name, retention and tags are pinned, and so the execution role's
# CreateLogStream/PutLogEvents grant can target a known group.

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

# Alarm sink for the per-queue DLQ-depth alarms in the messaging module.
resource "aws_sns_topic" "ops_alarms" {
  name = "${var.name_prefix}-ops-alarms"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ops-alarms"
  })
}

# Requires manual confirmation from the inbox after apply.
resource "aws_sns_topic_subscription" "ops_alarms_email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.ops_alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
