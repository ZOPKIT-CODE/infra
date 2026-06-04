# iam_irsa.tf
# -----------------------------------------------------------------------------
# IRSA (IAM Roles for Service Accounts) for both cluster controllers and the
# per-app workload roles.
#
# (A) Controller roles (load balancer controller, external-dns, external-secrets)
#     are provisioned via the upstream iam-role-for-service-accounts-eks module,
#     which wires the OIDC trust + managed-style inline policies for us.
# (B) Per-app workload roles (wrapper/crm/fa) are hand-rolled so we can attach
#     tightly-scoped, least-privilege policies that reference the exact ARNs of
#     the resources each app touches (SNS/SQS/EventBridge/S3/Cognito/Secrets).
#
# IRSA trust contract (per spec CONVENTIONS):
#   Federated   = module.eks.oidc_provider_arn
#   sub == system:serviceaccount:${local.namespace}:<app>
#   aud == sts.amazonaws.com
# -----------------------------------------------------------------------------

# =============================================================================
# (A) Controller IRSA roles
# =============================================================================

# AWS Load Balancer Controller -> manages the shared ALB for all suite Ingresses.
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                              = "${local.name_prefix}-aws-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# external-dns -> writes api/* and *.zopkit.com records into the Route53 zone
# based on the suite Ingresses.
module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                     = "${local.name_prefix}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/${local.route53_zone_id}"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}

# external-secrets (ESO) -> syncs Secrets Manager values into k8s Secrets via
# the aws-secretsmanager ClusterSecretStore.
module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                      = "${local.name_prefix}-external-secrets"
  attach_external_secrets_policy = true
  # Scope ESO reads to this suite's secret namespace (not all account secrets).
  external_secrets_secrets_manager_arns = ["arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.project}/${var.environment}/*"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

# =============================================================================
# (B) Per-app workload roles (wrapper / crm / fa)
# =============================================================================

# IRSA trust policy: federate the EKS OIDC provider and pin sub + aud so only
# the app's own ServiceAccount in the app namespace can assume the role.
data "aws_iam_policy_document" "app_assume_role" {
  for_each = local.apps

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.namespace}:${each.key}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  for_each = local.apps

  name               = "${local.name_prefix}-app-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.app_assume_role[each.key].json

  tags = {
    Name = "${local.name_prefix}-app-${each.key}"
  }
}

# =============================================================================
# (C) Per-app least-privilege permission policies
# =============================================================================

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
  name   = "${local.name_prefix}-app-wrapper-policy"
  role   = aws_iam_role.app["wrapper"].id
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
  name   = "${local.name_prefix}-app-crm-policy"
  role   = aws_iam_role.app["crm"].id
  policy = data.aws_iam_policy_document.crm.json
}

# ---------- fa ---------------------------------------------------------------
# Publishes to the business-events SNS topic (via fa_outbox), consumes
# accounting_events + business_events_fa in a separate consumer process, owns
# fa_receipts (RW) + reads claim checks, reads its own + Valkey secrets.
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
  name   = "${local.name_prefix}-app-fa-policy"
  role   = aws_iam_role.app["fa"].id
  policy = data.aws_iam_policy_document.fa.json
}
