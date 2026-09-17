locals {
  app_secret_keys = {
    wrapper = [
      "DATABASE_URL",
      "DATABASE_URL_READ",
      "MIGRATION_DATABASE_URL",
      "JWT_SECRET",
      "JWT_SECRET_PREVIOUS",
      "SESSION_SECRET",
      "OPERATIONS_JWT_SECRET",
      "SHARED_APP_JWT_SECRET",
      "STRIPE_SECRET_KEY",
      "STRIPE_WEBHOOK_SECRET",
      "RAZORPAY_KEY_ID",
      "RAZORPAY_KEY_SECRET",
      "BREVO_API_KEY",
      "SMTP_USER",
      "SMTP_PASS",
      "SES_SENDER_EMAIL",
      "SES_SENDER_NAME",
      "OPENAI_API_KEY",
      "SENTRY_DSN",
      "SUPABASE_SERVICE_ROLE_KEY",
      "SUPABASE_ANON_KEY",
      "WRAPPER_SECRET_KEY",
    ]

    crm = [
      "DATABASE_URL",
      "MIGRATION_DATABASE_URL",
      "SENTRY_DSN",
      "JWT_SECRET",
      "JWT_SECRET_PREVIOUS",
      "WRAPPER_SERVICE_TOKEN",
      "FA_JWT_SECRET",
      "BREVO_API_KEY",
      "BREVO_WEBHOOK_SECRET",
      "BREVO_SENDER_EMAIL",
      "BREVO_SENDER_NAME",
      "SES_SNS_WEBHOOK_SECRET",
      "ANTHROPIC_API_KEY",
      "GOOGLE_CLIENT_ID",
      "GOOGLE_CLIENT_SECRET",
      "MICROSOFT_CLIENT_ID",
      "MICROSOFT_CLIENT_SECRET",
      "INTEGRATION_ENCRYPTION_KEY",
      "SLACK_SIGNING_SECRET",
      "CLOUDINARY_API_KEY",
      "CLOUDINARY_API_SECRET",
    ]

    fa = [
      "DATABASE_URL",
      "MIGRATION_DATABASE_URL",
      "JWT_SECRET",
      "JWT_REFRESH_SECRET",
      "JWT_SECRET_PREVIOUS",
      "WRAPPER_API_KEY",
      "WRAPPER_FETCH_TOKEN",
      "FA_SERVICE_ACCOUNT_TOKEN",
      "INTERNAL_API_SECRET",
      "SSE_INTERNAL_SECRET",
      "BOOTSTRAP_TOKEN",
      "TENANT_CONFIG_ENCRYPTION_KEY",
      "TAX_ENCRYPTION_KEY",
      "ANTHROPIC_API_KEY",
      "EXCHANGE_RATE_API_KEY",
      "SMTP_USER",
      "SMTP_PASS",
      "TEMPORAL_API_KEY",
      "CORS_ORIGINS",
    ]

    academy = [
      "DATABASE_URL",
      "JWT_SECRET",
      "REFRESH_TOKEN_SECRET",
      "SUPABASE_URL",
      "SUPABASE_ANON_KEY",
      "SUPABASE_SERVICE_KEY",
      "GOOGLE_OAUTH_CLIENT_ID",
      "GOOGLE_OAUTH_CLIENT_SECRET",
      "CLOUDINARY_CLOUD_NAME",
      "CLOUDINARY_API_KEY",
      "CLOUDINARY_API_SECRET",
    ]

    entertainment-erp = [
      "DATABASE_URL",
      "JWT_SECRET",
    ]

    lens = [
      "DATABASE_URL",
      "DIRECT_URL",
      "MIGRATION_DATABASE_URL",
      "DATABASE_SSL_CA",
      "JWT_SECRET",
      "EXTERNAL_ISSUER_URL",
      "EXTERNAL_OAUTH_DOMAIN",
      "EXTERNAL_CLIENT_ID",
      "EXTERNAL_CLIENT_SECRET",
      "GOOGLE_CLIENT_ID",
      "GOOGLE_CLIENT_SECRET",
      "GOOGLE_STORAGE_CLIENT_ID",
      "GOOGLE_STORAGE_CLIENT_SECRET",
      "STRIPE_SECRET_KEY",
      "STRIPE_WEBHOOK_SECRET",
      "STRIPE_PUBLISHABLE_KEY",
      "RAZORPAY_KEY_ID",
      "RAZORPAY_KEY_SECRET",
      "RAZORPAY_WEBHOOK_SECRET",
      "RESEND_API_KEY",
      "BREVO_API_KEY",
      "STORAGE_OAUTH_STATE_SECRET",
      "STORAGE_TOKEN_ENCRYPTION_KEY",
      "ADMIN_EMAILS",
    ]
  }
}

resource "aws_secretsmanager_secret" "app" {
  for_each = local.apps

  name                    = "${var.project}/${var.environment}/${each.key}"
  description             = "Runtime secrets for the ${each.key} backend. Populate before the first task starts; ECS injects them via the task definition's secrets block."
  recovery_window_in_days = 7

  tags = {
    Name = "${local.name_prefix}-${each.key}-secrets"
    App  = each.key
  }
}

resource "aws_secretsmanager_secret_version" "app" {
  for_each = local.apps

  secret_id     = aws_secretsmanager_secret.app[each.key].id
  secret_string = jsonencode({ for k in local.app_secret_keys[each.key] : k => "REPLACE_ME" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
