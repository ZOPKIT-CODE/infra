# ---------------------------------------------------------------------------
# iam.tf — ECS task roles + ONE shared execution role. Replaces the EKS stack's
# iam_irsa.tf (no OIDC, no controller IRSA, no ESO role).
#
#   (A) ecs-tasks.amazonaws.com assume-role trust (shared by all task roles).
#   (B) 3 per-app TASK roles (wrapper / crm / fa) carrying the least-privilege
#       runtime policies ported VERBATIM from the EKS stack's iam_irsa.tf §(C)
#       — same SIDs, actions, and ARN expressions. fa-web AND fa-consumer share
#       the single "fa" task role.
#   (C) 1 shared EXECUTION role: AmazonECSTaskExecutionRolePolicy (ECR pull +
#       CloudWatch logs) plus an inline secretsmanager:GetSecretValue grant on
#       the app + valkey secrets so the agent can resolve the task def `secrets`
#       valueFrom ARNs at launch.
# ---------------------------------------------------------------------------

# =============================================================================
# (A) Task-role trust — principal is the ECS tasks service, NOT an OIDC IdP.
# =============================================================================
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# =============================================================================
# (B) Per-app task roles (wrapper / crm / fa). fa-web + fa-consumer share "fa".
# =============================================================================
resource "aws_iam_role" "task" {
  for_each = local.apps # wrapper | crm | fa

  name               = "${local.name_prefix}-task-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Name = "${local.name_prefix}-task-${each.key}"
  }
}

# ---------- wrapper ----------------------------------------------------------
# Publishes SNS (both inter-app topics), consumes its own SQS queues + the three
# notification queues, owns the claim-check + logos S3 buckets, drives Cognito
# admin APIs, and reads its own + the Valkey secret.
data "aws_iam_policy_document" "wrapper" {
  # SNS publish on both inter-app topics.
  statement {
    sid       = "SnsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [for k in ["inter_app_events", "inter_app_broadcast"] : aws_sns_topic.topics[k].arn]
  }

  # SQS consume + send on wrapper_events + the three notification queues.
  statement {
    sid    = "SqsConsume"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:SendMessage",
    ]
    resources = [
      for k in ["wrapper_events", "notifications_immediate", "notifications_bulk", "notifications_scheduled"] :
      aws_sqs_queue.main[k].arn
    ]
  }

  # Send to the matching DLQs (manual redrive / poison-message handling).
  statement {
    sid     = "SqsDlqSend"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    resources = [
      for k in ["wrapper_events", "notifications_immediate", "notifications_bulk", "notifications_scheduled"] :
      aws_sqs_queue.dlq[k].arn
    ]
  }

  # S3 read/write on the claim-check + wrapper logos buckets.
  statement {
    sid    = "S3Buckets"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = concat(
      [for k in ["claim_check", "wrapper_logos"] : aws_s3_bucket.buckets[k].arn],
      [for k in ["claim_check", "wrapper_logos"] : "${aws_s3_bucket.buckets[k].arn}/*"],
      # When reusing an existing logo bucket (staging points at the shared dev
      # bucket so blog/logo images referenced by the shared dev DB resolve).
      var.logo_bucket_override != "" ? ["arn:aws:s3:::${var.logo_bucket_override}", "arn:aws:s3:::${var.logo_bucket_override}/*"] : [],
    )
  }

  # Cognito admin APIs scoped to the suite user pool.
  statement {
    sid    = "CognitoAdmin"
    effect = "Allow"
    actions = [
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminDeleteUser",
      "cognito-idp:AdminGetUser",
      "cognito-idp:AdminUpdateUserAttributes",
      "cognito-idp:AdminSetUserPassword",
      "cognito-idp:AdminInitiateAuth",
      "cognito-idp:AdminRespondToAuthChallenge",
      "cognito-idp:AdminEnableUser",
      "cognito-idp:AdminDisableUser",
      "cognito-idp:AdminAddUserToGroup",
      "cognito-idp:AdminRemoveUserFromGroup",
      "cognito-idp:AdminListGroupsForUser",
      "cognito-idp:AdminUserGlobalSignOut",
      "cognito-idp:AdminResetUserPassword",
      "cognito-idp:ListUsers",
    ]
    resources = [aws_cognito_user_pool.this.arn]
  }

  # Secrets Manager read on the app secret + the shared Valkey secret.
  statement {
    sid     = "SecretsRead"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.app["wrapper"].arn,
      aws_secretsmanager_secret.valkey.arn,
    ]
  }
}

resource "aws_iam_role_policy" "wrapper" {
  name   = "${local.name_prefix}-task-wrapper-policy"
  role   = aws_iam_role.task["wrapper"].id
  policy = data.aws_iam_policy_document.wrapper.json
}

# ---------- crm --------------------------------------------------------------
# Consumes crm_events + business_events_crm, publishes to the business-events
# SNS topic, sends email via SES, owns crm_attachments (RW) + reads claim
# checks, reads its own + Valkey secrets.
data "aws_iam_policy_document" "crm" {
  # SQS consume + send on crm_events + business_events_crm.
  statement {
    sid    = "SqsConsume"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:SendMessage",
    ]
    resources = [
      for k in ["crm_events", "business_events_crm"] : aws_sqs_queue.main[k].arn
    ]
  }

  statement {
    sid     = "SqsDlqSend"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    resources = [
      for k in ["crm_events", "business_events_crm"] : aws_sqs_queue.dlq[k].arn
    ]
  }

  # Publish onto the business-events SNS topic.
  statement {
    sid       = "BusinessEventsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.topics["business_events"].arn]
  }

  # SES send. SES email-sending authorization is identity/configuration-set
  # scoped rather than ARN scoped, so the resource is "*".
  statement {
    sid       = "SesSend"
    effect    = "Allow"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }

  # S3: read/write crm_attachments, read-only claim_check.
  statement {
    sid    = "S3Attachments"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.buckets["crm_attachments"].arn,
      "${aws_s3_bucket.buckets["crm_attachments"].arn}/*",
    ]
  }

  statement {
    sid    = "S3ClaimCheckRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.buckets["claim_check"].arn,
      "${aws_s3_bucket.buckets["claim_check"].arn}/*",
    ]
  }

  statement {
    sid     = "SecretsRead"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.app["crm"].arn,
      aws_secretsmanager_secret.valkey.arn,
    ]
  }
}

resource "aws_iam_role_policy" "crm" {
  name   = "${local.name_prefix}-task-crm-policy"
  role   = aws_iam_role.task["crm"].id
  policy = data.aws_iam_policy_document.crm.json
}

# ---------- fa ---------------------------------------------------------------
# Publishes to the business-events SNS topic (via fa_outbox), consumes
# accounting_events + business_events_fa in a separate consumer process, owns
# fa_receipts (RW) + reads claim checks, reads its own + Valkey secrets.
# This single role backs BOTH the fa-web and fa-consumer ECS services.
data "aws_iam_policy_document" "fa" {
  statement {
    sid       = "BusinessEventsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.topics["business_events"].arn]
  }

  statement {
    sid    = "SqsConsume"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:SendMessage",
    ]
    resources = [
      for k in ["accounting_events", "business_events_fa"] : aws_sqs_queue.main[k].arn
    ]
  }

  statement {
    sid     = "SqsDlqSend"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    resources = [
      for k in ["accounting_events", "business_events_fa"] : aws_sqs_queue.dlq[k].arn
    ]
  }

  # S3: read/write fa_receipts, read-only claim_check.
  statement {
    sid    = "S3Receipts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.buckets["fa_receipts"].arn,
      "${aws_s3_bucket.buckets["fa_receipts"].arn}/*",
    ]
  }

  statement {
    sid    = "S3ClaimCheckRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.buckets["claim_check"].arn,
      "${aws_s3_bucket.buckets["claim_check"].arn}/*",
    ]
  }

  statement {
    sid     = "SecretsRead"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.app["fa"].arn,
      aws_secretsmanager_secret.valkey.arn,
    ]
  }
}

resource "aws_iam_role_policy" "fa" {
  name   = "${local.name_prefix}-task-fa-policy"
  role   = aws_iam_role.task["fa"].id
  policy = data.aws_iam_policy_document.fa.json
}

# =============================================================================
# (C) Shared task EXECUTION role.
# =============================================================================
resource "aws_iam_role" "execution" {
  name               = "${local.name_prefix}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Name = "${local.name_prefix}-task-execution"
  }
}

# Managed policy covers ECR pull (GetAuthorizationToken / BatchGetImage /
# GetDownloadUrlForLayer) + CloudWatch logs (CreateLogStream / PutLogEvents).
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Inline grant so the ECS agent can resolve the task def `secrets` valueFrom
# ARNs (app secrets + the valkey secret) at task launch.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid     = "GetTaskSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = concat(
      [for k in keys(local.apps) : aws_secretsmanager_secret.app[k].arn],
      [aws_secretsmanager_secret.valkey.arn],
    )
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${local.name_prefix}-task-execution-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}
