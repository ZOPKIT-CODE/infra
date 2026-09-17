resource "aws_sns_topic" "topics" {
  for_each = var.sns_topics

  name = each.value
  tags = {
    Name = each.value
  }
}

resource "aws_sqs_queue" "dlq" {
  for_each = { for k, v in var.sqs_queues : k => v if v.dlq }

  name                      = "${var.name_prefix}-${replace(each.key, "_", "-")}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${var.name_prefix}-${replace(each.key, "_", "-")}-dlq"
    App  = each.value.app
  }
}

resource "aws_sqs_queue" "main" {
  for_each = var.sqs_queues

  name                       = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true

  redrive_policy = each.value.dlq ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  }) : null

  tags = {
    Name = "${var.name_prefix}-${replace(each.key, "_", "-")}"
    App  = each.value.app
  }
}

resource "aws_sns_topic_subscription" "targeted" {
  for_each = { for k, v in var.sqs_queues : k => v if v.source == "sns" }

  topic_arn            = aws_sns_topic.topics["inter_app_events"].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.main[each.key].arn
  raw_message_delivery = true

  filter_policy = each.value.filter_target != "" ? jsonencode({
    targetApplication = [each.value.filter_target]
  }) : null
  filter_policy_scope = each.value.filter_target != "" ? "MessageAttributes" : null
}

resource "aws_sns_topic_subscription" "broadcast" {
  for_each = { for k, v in var.sqs_queues : k => v if v.source == "sns" }

  topic_arn            = aws_sns_topic.topics["inter_app_broadcast"].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.main[each.key].arn
  raw_message_delivery = true
}

resource "aws_sns_topic_subscription" "business" {
  for_each = { for k, v in var.sqs_queues : k => v if v.source == "sns_business" }

  topic_arn            = aws_sns_topic.topics["business_events"].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.main[each.key].arn
  raw_message_delivery = true

  filter_policy       = jsonencode({ sourceSystem = [{ "anything-but" = [each.value.app] }] })
  filter_policy_scope = "MessageAttributes"
}

data "aws_iam_policy_document" "queue" {
  for_each = var.sqs_queues

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
  for_each = var.sqs_queues

  queue_url = aws_sqs_queue.main[each.key].id
  policy    = data.aws_iam_policy_document.queue[each.key].json
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = { for k, v in var.sqs_queues : k => v if v.dlq }

  alarm_name          = "${var.name_prefix}-${replace(each.key, "_", "-")}-dlq-not-empty"
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

  alarm_actions = [var.ops_alarms_topic_arn]
  ok_actions    = [var.ops_alarms_topic_arn]

  tags = {
    Name = "${var.name_prefix}-${replace(each.key, "_", "-")}-dlq-not-empty"
    App  = each.value.app
  }
}

resource "aws_cloudwatch_metric_alarm" "accounting_backlog_expiry" {
  alarm_name          = "${var.name_prefix}-accounting-events-nearing-expiry"
  alarm_description   = "Oldest accounting-events message is > 11 days old; SQS silently drops it at 14. Start the FA consumer (or replay from wrapper outbox) before the backlog evaporates."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 950400
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = "${var.name_prefix}-accounting-events"
  }

  alarm_actions = [var.ops_alarms_topic_arn]
  ok_actions    = [var.ops_alarms_topic_arn]

  tags = {
    Name = "${var.name_prefix}-accounting-events-nearing-expiry"
    App  = "fa"
  }
}
