variable "name_prefix" {
  description = "Resource name prefix, \"<project>-<environment>\"."
  type        = string
}

variable "sns_topics" {
  description = "Topic key -> full topic name (local.sns_topics). Keys inter_app_events, inter_app_broadcast and business_events are required."
  type        = map(string)
}

variable "sqs_queues" {
  description = "Queue key -> { app, dlq, source, filter_target } (local.sqs_queues). `source` is one of \"sns\", \"sns_business\" or \"direct\"."
  type = map(object({
    app           = string
    dlq           = bool
    source        = string
    filter_target = string
  }))
}

variable "ops_alarms_topic_arn" {
  description = "SNS topic the DLQ-depth alarms publish to (from ./modules/observability)."
  type        = string
}
