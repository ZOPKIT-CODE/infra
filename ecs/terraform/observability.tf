# ---------------------------------------------------------------------------
# Observability: CloudWatch log groups + the ops alarm SNS topic.
#
# App logs: each ECS Fargate task ships container stdout/stderr directly to
# CloudWatch via the awslogs log driver (configured in modules/ecs-service).
# Creating the groups here (rather than letting the awslogs driver auto-create
# them) lets us pin the name, retention and tags, and lets the execution role's
# CreateLogStream/PutLogEvents permissions target a known group. Each service's
# task def points its awslogs-group at "/ecs/${local.name_prefix}/<service>".
#
# Pinned addresses:
#   aws_cloudwatch_log_group.service[<service>]  for_each = local.services
#   aws_sns_topic.ops_alarms                     ops alarm topic (messaging.tf DLQ alarms reference it)
# ---------------------------------------------------------------------------

# Per-service CloudWatch log group. One per ECS service (4 total: wrapper-web,
# crm-web, fa-web, fa-consumer). The ecs-service module's awslogs driver targets
# this name so application logs land here.
resource "aws_cloudwatch_log_group" "service" {
  for_each = local.services

  name              = "/ecs/${local.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = {
    Name    = "${local.name_prefix}-${each.key}-logs"
    Service = each.key
    App     = each.value.app
  }
}

# ---------------------------------------------------------------------------
# Ops alarm topic. CloudWatch alarms (e.g. the per-queue DLQ-depth alarms in
# messaging.tf) publish here. Subscribe an email endpoint when var.alarm_email
# is set; the subscription requires manual confirmation from the inbox.
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "ops_alarms" {
  name = "${local.name_prefix}-ops-alarms"

  tags = {
    Name = "${local.name_prefix}-ops-alarms"
  }
}

# Optional email subscription (skipped when var.alarm_email == "").
# Confirm the subscription from the email AWS sends after apply.
resource "aws_sns_topic_subscription" "ops_alarms_email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.ops_alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
