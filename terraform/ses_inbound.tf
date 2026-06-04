# ===========================================================================
# ses_inbound.tf — CRM SES INBOUND EMAIL PIPELINE (optional, OFF by default)
#
# Gated behind var.enable_ses_inbound (default false): a plain `terraform apply`
# does NOT create this pipeline, because it has out-of-band prerequisites and the
# handler must be dependency-bundled. Set enable_ses_inbound = true to turn it on.
#
# Trigger model = S3 -> Lambda (matches the handler, which expects an S3
# ObjectCreated event: event.Records[0].s3.bucket/.object — see
# b2b-crm/infra/lambda/ses-inbound-handler/index.mjs:105). SES itself only stores
# the raw MIME to S3 via an s3_action; it does NOT invoke the Lambda directly
# (an SES lambda_action would deliver an SES-shaped event the handler can't read).
#
# Flow:
#   inbound mail -> SES receipt rule (active set) -> s3_action: store MIME in the
#   ses_inbound bucket under inbound/ -> S3 ObjectCreated notification -> Lambda
#   -> parse (mailparser) + HMAC-sign + POST to https://<crm-api>/api/webhooks/inbound/ses
#
# PREREQUISITES (NOT managed here):
#   - SES domain identity verification for the inbound domain.
#   - MX record -> 10 inbound-smtp.<region>.amazonaws.com (SES inbound is region-limited).
#   - The receipt rule set, Lambda, and ses_inbound bucket must all be in the SAME
#     region as the SES inbound endpoint (everything here uses the default provider).
#   - WEBHOOK_SECRET / TENANT_SLUG must be set to the tenant's real values.
# ===========================================================================

locals {
  ses_enabled     = var.enable_ses_inbound ? 1 : 0
  ses_handler_dir = "${path.module}/../../../b2b-crm/infra/lambda/ses-inbound-handler"
}

# ---------------------------------------------------------------------------
# Bundle the handler with its runtime deps (mailparser, @aws-sdk/client-s3).
# The source dir ships WITHOUT node_modules, so install prod deps before zipping;
# the archive depends on this so it never bundles an import-broken function.
# ---------------------------------------------------------------------------
resource "null_resource" "ses_inbound_deps" {
  count = local.ses_enabled

  triggers = {
    pkg = filemd5("${local.ses_handler_dir}/package.json")
    src = filemd5("${local.ses_handler_dir}/index.mjs")
  }

  provisioner "local-exec" {
    working_dir = local.ses_handler_dir
    command     = "npm ci --omit=dev || npm install --omit=dev"
  }
}

data "archive_file" "ses_inbound" {
  count       = local.ses_enabled
  type        = "zip"
  source_dir  = local.ses_handler_dir
  output_path = "${path.module}/.build/ses-inbound-handler.zip"

  depends_on = [null_resource.ses_inbound_deps]
}

# ---------------------------------------------------------------------------
# Execution role: write its own logs + read the MIME objects from S3.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ses_inbound_lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ses_inbound_lambda" {
  count              = local.ses_enabled
  name               = "${local.name_prefix}-ses-inbound-lambda"
  assume_role_policy = data.aws_iam_policy_document.ses_inbound_lambda_assume.json
  tags               = { Name = "${local.name_prefix}-ses-inbound-lambda" }
}

resource "aws_cloudwatch_log_group" "ses_inbound_lambda" {
  count             = local.ses_enabled
  name              = "/aws/lambda/${local.name_prefix}-ses-inbound"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${local.name_prefix}-ses-inbound" }
}

data "aws_iam_policy_document" "ses_inbound_lambda" {
  statement {
    sid     = "Logs"
    effect  = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-ses-inbound:*",
    ]
  }
  statement {
    sid       = "ReadInboundMime"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.buckets["ses_inbound"].arn}/*"]
  }
}

resource "aws_iam_role_policy" "ses_inbound_lambda" {
  count  = local.ses_enabled
  name   = "${local.name_prefix}-ses-inbound-lambda"
  role   = aws_iam_role.ses_inbound_lambda[0].id
  policy = data.aws_iam_policy_document.ses_inbound_lambda.json
}

# ---------------------------------------------------------------------------
# The handler function. WEBHOOK_SECRET / TENANT_SLUG are placeholders — set them
# to the tenant's real values (the secret must match the tenant inbox HMAC key).
# AWS_REGION is a RESERVED Lambda env var (auto-injected) — do NOT set it here.
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "ses_inbound" {
  count         = local.ses_enabled
  function_name = "${local.name_prefix}-ses-inbound"
  description   = "Parse SES inbound MIME (from S3) and POST a signed payload to the CRM webhook"

  role             = aws_iam_role.ses_inbound_lambda[0].arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.ses_inbound[0].output_path
  source_code_hash = data.archive_file.ses_inbound[0].output_base64sha256
  timeout          = 30

  environment {
    variables = {
      WEBHOOK_URL    = "https://${local.fqdn["crm"].api}/api/webhooks/inbound/ses"
      WEBHOOK_SECRET = "REPLACE_ME" # tenant inbox HMAC key
      TENANT_SLUG    = "REPLACE_ME" # tenant slug -> X-Tenant-Slug header
    }
  }

  depends_on = [aws_cloudwatch_log_group.ses_inbound_lambda]
  tags       = { Name = "${local.name_prefix}-ses-inbound" }
}

# Allow S3 (not SES) to invoke the Lambda, scoped to the ses_inbound bucket.
resource "aws_lambda_permission" "ses_inbound_s3" {
  count          = local.ses_enabled
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.ses_inbound[0].function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.buckets["ses_inbound"].arn
  source_account = local.account_id
}

# Fire the Lambda when SES drops a new MIME object under inbound/.
resource "aws_s3_bucket_notification" "ses_inbound" {
  count  = local.ses_enabled
  bucket = aws_s3_bucket.buckets["ses_inbound"].id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ses_inbound[0].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "inbound/"
  }

  depends_on = [aws_lambda_permission.ses_inbound_s3]
}

# ---------------------------------------------------------------------------
# Bucket policy: SES needs s3:PutObject to deliver MIME into the bucket. This is
# a service-principal policy with a SourceAccount condition (NOT public), so it
# coexists with the bucket's block-public-access settings. Owned here because
# ses_inbound.tf is the sole consumer of this bucket.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ses_inbound_bucket" {
  statement {
    sid       = "AllowSESPuts"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.buckets["ses_inbound"].arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "ses_inbound" {
  count  = local.ses_enabled
  bucket = aws_s3_bucket.buckets["ses_inbound"].id
  policy = data.aws_iam_policy_document.ses_inbound_bucket.json
}

# ---------------------------------------------------------------------------
# SES receipt rule set + rule. s3_action only — the S3 notification (above)
# drives the Lambda, so the handler receives the S3 event shape it expects.
# ---------------------------------------------------------------------------
resource "aws_ses_receipt_rule_set" "inbound" {
  count         = local.ses_enabled
  rule_set_name = "${local.name_prefix}-inbound"
}

resource "aws_ses_active_receipt_rule_set" "inbound" {
  count         = local.ses_enabled
  rule_set_name = aws_ses_receipt_rule_set.inbound[0].rule_set_name
}

resource "aws_ses_receipt_rule" "inbound" {
  count         = local.ses_enabled
  name          = "${local.name_prefix}-inbound-to-s3"
  rule_set_name = aws_ses_receipt_rule_set.inbound[0].rule_set_name
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Require"

  s3_action {
    bucket_name       = aws_s3_bucket.buckets["ses_inbound"].id
    object_key_prefix = "inbound/"
    position          = 1
  }

  # SES must be able to PutObject before the rule is usable.
  depends_on = [aws_s3_bucket_policy.ses_inbound]
}
