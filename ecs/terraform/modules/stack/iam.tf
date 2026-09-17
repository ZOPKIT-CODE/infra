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

resource "aws_iam_role" "task" {
  for_each = local.apps

  name               = "${local.name_prefix}-task-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Name = "${local.name_prefix}-task-${each.key}"
  }
}

data "aws_iam_policy_document" "wrapper" {
  statement {
    sid       = "SnsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [for k in ["inter_app_events", "inter_app_broadcast"] : module.messaging.topic_arns[k]]
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
      for k in ["wrapper_events", "notifications_immediate", "notifications_bulk", "notifications_scheduled"] :
      module.messaging.queue_arns[k]
    ]
  }

  statement {
    sid     = "SqsDlqSend"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    resources = [
      for k in ["wrapper_events", "notifications_immediate", "notifications_bulk", "notifications_scheduled"] :
      module.messaging.dlq_arns[k]
    ]
  }

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
      var.logo_bucket_override != "" ? ["arn:aws:s3:::${var.logo_bucket_override}", "arn:aws:s3:::${var.logo_bucket_override}/*"] : [],
    )
  }

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

  statement {
    sid     = "SecretsRead"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = concat(
      [aws_secretsmanager_secret.app["wrapper"].arn],
      var.enable_valkey ? [aws_secretsmanager_secret.valkey[0].arn] : [],
    )
  }
}

resource "aws_iam_role_policy" "wrapper" {
  name   = "${local.name_prefix}-task-wrapper-policy"
  role   = aws_iam_role.task["wrapper"].id
  policy = data.aws_iam_policy_document.wrapper.json
}

data "aws_iam_policy_document" "crm" {
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
      for k in ["crm_events", "business_events_crm"] : module.messaging.queue_arns[k]
    ]
  }

  statement {
    sid     = "SqsDlqSend"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    resources = [
      for k in ["crm_events", "business_events_crm"] : module.messaging.dlq_arns[k]
    ]
  }

  statement {
    sid       = "BusinessEventsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [module.messaging.topic_arns["business_events"]]
  }

  statement {
    sid       = "SesSend"
    effect    = "Allow"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }

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
    resources = concat(
      [aws_secretsmanager_secret.app["crm"].arn],
      var.enable_valkey ? [aws_secretsmanager_secret.valkey[0].arn] : [],
    )
  }
}

resource "aws_iam_role_policy" "crm" {
  name   = "${local.name_prefix}-task-crm-policy"
  role   = aws_iam_role.task["crm"].id
  policy = data.aws_iam_policy_document.crm.json
}

data "aws_iam_policy_document" "fa" {
  statement {
    sid       = "BusinessEventsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [module.messaging.topic_arns["business_events"]]
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
      for k in ["accounting_events", "business_events_fa"] : module.messaging.queue_arns[k]
    ]
  }

  statement {
    sid     = "SqsDlqSend"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    resources = [
      for k in ["accounting_events", "business_events_fa"] : module.messaging.dlq_arns[k]
    ]
  }

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
    resources = concat(
      [aws_secretsmanager_secret.app["fa"].arn],
      var.enable_valkey ? [aws_secretsmanager_secret.valkey[0].arn] : [],
    )
  }
}

resource "aws_iam_role_policy" "fa" {
  name   = "${local.name_prefix}-task-fa-policy"
  role   = aws_iam_role.task["fa"].id
  policy = data.aws_iam_policy_document.fa.json
}

data "aws_iam_policy_document" "lens" {
  statement {
    sid     = "SecretsRead"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.app["lens"].arn,
    ]
  }
}

resource "aws_iam_role_policy" "lens" {
  name   = "${local.name_prefix}-task-lens-policy"
  role   = aws_iam_role.task["lens"].id
  policy = data.aws_iam_policy_document.lens.json
}

resource "aws_iam_role" "execution" {
  name               = "${local.name_prefix}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Name = "${local.name_prefix}-task-execution"
  }
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid     = "GetTaskSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = concat(
      [for k in keys(local.apps) : aws_secretsmanager_secret.app[k].arn],
      var.enable_valkey ? [aws_secretsmanager_secret.valkey[0].arn] : [],
      var.enable_rds ? [aws_secretsmanager_secret.rds_master[0].arn] : [],
      compact([module.mathesar.secret_arn]),
    )
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${local.name_prefix}-task-execution-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}
