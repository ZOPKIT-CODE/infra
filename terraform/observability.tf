# ---------------------------------------------------------------------------
# Observability: CloudWatch log groups + the ops alarm SNS topic.
#
# App logs: each backend container writes structured logs to stdout/stderr.
# Inside the cluster, a Fluent Bit DaemonSet (Amazon CloudWatch Container
# Insights / aws-for-fluent-bit) tails the container logs and ships them to
# these per-app log groups. Creating the groups here (rather than letting
# Fluent Bit auto-create them) lets us pin the name, retention, encryption and
# tags. The Fluent Bit install itself is OPTIONAL and lives outside this file
# (addons.tf / a separate aws-observability namespace); if it is not deployed
# these groups simply stay empty. Point its `log_group_name` at
# "/eks/${local.name_prefix}/<app>" to land logs in the matching group.
#
# Pinned addresses (see .iac-spec.md "ADDITIONAL PINNED ADDRESSES"):
#   aws_cloudwatch_log_group.app[<app>]   for_each = local.apps
#   aws_sns_topic.ops_alarms              ops alarm topic (messaging.tf DLQ alarms reference it)
# ---------------------------------------------------------------------------

# Per-app CloudWatch log group. Name format is what Fluent Bit / Container
# Insights should target so application logs land here.
resource "aws_cloudwatch_log_group" "app" {
  for_each = local.apps

  name              = "/eks/${local.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${local.name_prefix}-${each.key}-logs"
    App  = each.key
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
