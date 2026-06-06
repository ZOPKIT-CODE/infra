# ---------------------------------------------------------------------------
# Messaging substrate — TWO buses.
#
#   1. Wrapper "platform bus" = SNS:
#        - inter_app_events    (targeted, filtered on message attribute
#                               `targetApplication`)
#        - inter_app_broadcast (fanout, no filter)
#      Each app's *_events SQS queue subscribes to BOTH topics. Wrapper's
#      notification queues are written to DIRECTLY by the producer (source
#      "direct"), so they get no SNS subscription.
#
#   2. CRM/FA "business bus" = SNS topic `business_events` -> per-app SQS.
#      Each business-events queue subscribes with a filter policy excluding its
#      own app's events (the loop-guard, enforced at the SNS edge).
#
# Every main queue has a redrive policy to a dedicated DLQ (maxReceiveCount 5),
# and a CloudWatch alarm fires to the ops topic when any DLQ is non-empty.
#
# NOTE: the SNS message-attribute used for targeted routing is assumed to be
# `targetApplication` (see summary). Adjust the filter_policy key if the
# wrapper publisher uses a different attribute name.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. SNS topics (platform bus).
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "topics" {
  for_each = local.sns_topics

  name = each.value
  tags = {
    Name = each.value
  }
}

# ---------------------------------------------------------------------------
# 2. SQS — DLQs first (so main queues can redrive to them), then main queues.
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  for_each = { for k, v in local.sqs_queues : k => v if v.dlq }

  name                      = "${local.name_prefix}-${replace(each.key, "_", "-")}-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${local.name_prefix}-${replace(each.key, "_", "-")}-dlq"
    App  = each.value.app
  }
}

resource "aws_sqs_queue" "main" {
  for_each = local.sqs_queues

  name                       = "${local.name_prefix}-${replace(each.key, "_", "-")}"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20 # long polling
  sqs_managed_sse_enabled    = true

  # Move messages to the DLQ after 5 failed receives.
  redrive_policy = each.value.dlq ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  }) : null

  tags = {
    Name = "${local.name_prefix}-${replace(each.key, "_", "-")}"
    App  = each.value.app
  }
}

# ---------------------------------------------------------------------------
# 3. SNS -> SQS subscriptions.
#    Each queue with source == "sns" subscribes to BOTH SNS topics:
#      - inter_app_events    : filtered on targetApplication = [filter_target]
#                              (only when filter_target is non-empty)
#      - inter_app_broadcast : unfiltered fanout
#    raw_message_delivery=true so the consumer receives the producer body as-is.
# ---------------------------------------------------------------------------
resource "aws_sns_topic_subscription" "targeted" {
  for_each = { for k, v in local.sqs_queues : k => v if v.source == "sns" }

  topic_arn            = aws_sns_topic.topics["inter_app_events"].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.main[each.key].arn
  raw_message_delivery = true

  # Only deliver messages whose targetApplication attribute matches this app.
  filter_policy = each.value.filter_target != "" ? jsonencode({
    targetApplication = [each.value.filter_target]
  }) : null
  filter_policy_scope = each.value.filter_target != "" ? "MessageAttributes" : null
}

resource "aws_sns_topic_subscription" "broadcast" {
  for_each = { for k, v in local.sqs_queues : k => v if v.source == "sns" }

  topic_arn            = aws_sns_topic.topics["inter_app_broadcast"].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.main[each.key].arn
  raw_message_delivery = true
  # No filter: every SNS-sourced queue receives all broadcasts.
}

# Business bus: each business-events queue subscribes to the business_events
# topic, filtered to EXCLUDE events whose sourceSystem == its own app (the
# loop-guard, applied at the SNS edge). raw_message_delivery=true so the SQS
# body is the BusinessEvent JSON and trace context rides in MessageAttributes.
resource "aws_sns_topic_subscription" "business" {
  for_each = { for k, v in local.sqs_queues : k => v if v.source == "sns_business" }

  topic_arn            = aws_sns_topic.topics["business_events"].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.main[each.key].arn
  raw_message_delivery = true

  filter_policy       = jsonencode({ sourceSystem = [{ "anything-but" = [each.value.app] }] })
  filter_policy_scope = "MessageAttributes"
}

# ---------------------------------------------------------------------------
# 4. Queue access policies — allow SNS (the two platform topics + the business
#    bus topic) to deliver to each queue. Scoped via ArnLike on aws:SourceArn to
#    the topic ARNs; a queue only actually receives from topics it subscribes to.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "queue" {
  for_each = local.sqs_queues

  # SNS -> SQS (platform bus + business bus).
  statement {
    sid       = "AllowSNSDelivery"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        aws_sns_topic.topics["inter_app_events"].arn,
        aws_sns_topic.topics["inter_app_broadcast"].arn,
        aws_sns_topic.topics["business_events"].arn,
      ]
    }
  }
}

resource "aws_sqs_queue_policy" "main" {
  for_each = local.sqs_queues

  queue_url = aws_sqs_queue.main[each.key].id
  policy    = data.aws_iam_policy_document.queue[each.key].json
}

# ---------------------------------------------------------------------------
# 5. (The EventBridge custom bus + rules + targets were removed when the
#    business bus moved to the `business_events` SNS topic above. Publishers use
#    sns:Publish; consumers subscribe via aws_sns_topic_subscription.business.)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 6. DLQ depth alarms — fire to the ops topic whenever a DLQ is non-empty.
#    aws_sns_topic.ops_alarms is owned by observability.tf.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = { for k, v in local.sqs_queues : k => v if v.dlq }

  alarm_name          = "${local.name_prefix}-${replace(each.key, "_", "-")}-dlq-not-empty"
  alarm_description   = "Messages have landed in the ${each.key} DLQ (delivery/processing is failing)."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq[each.key].name
  }

  alarm_actions = [aws_sns_topic.ops_alarms.arn]
  ok_actions    = [aws_sns_topic.ops_alarms.arn]

  tags = {
    Name = "${local.name_prefix}-${replace(each.key, "_", "-")}-dlq-not-empty"
    App  = each.value.app
  }
}
