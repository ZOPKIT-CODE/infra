################################################################################
# secrets.tf — Per-app AWS Secrets Manager secrets (one per suite app)
#
# Each app gets a single JSON secret at `${var.project}/${var.environment}/<app>`
# (e.g. zopkit/prod/wrapper). The values authored here are PLACEHOLDERS only —
# every key is set to "REPLACE_ME". Operators MUST populate the real values
# BEFORE pods start; External Secrets Operator (see addons.tf / externalsecret.yaml)
# syncs each of these into a Kubernetes Secret consumed by the Deployment's
# `secretRef`.
#
# AWS credentials are intentionally NOT included here — IRSA (aws_iam_role.app,
# see iam_irsa.tf) provides the pod's AWS access at runtime.
#
# The `lifecycle { ignore_changes = [secret_string] }` block ensures Terraform
# never clobbers operator-populated values on subsequent applies.
################################################################################

locals {
  # Per-app secret env-var key sets. Keys become the JSON keys of each secret;
  # all values are the "REPLACE_ME" placeholder until operators populate them.
  app_secret_keys = {
    wrapper = [
      "DATABASE_URL",
      "DATABASE_URL_READ",
      # Privileged migrator role URL — used ONLY by the one-off `run-migrations.js`
      # task (reads MIGRATION_DATABASE_URL first). On least-privilege RDS, DATABASE_URL
      # (app_user) is DML-only and cannot create/own __drizzle_migrations, so the
      # migration must run as the migrator role. The long-running app ignores this key.
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
      "OPENAI_API_KEY",
      "SENTRY_DSN",
      "SUPABASE_SERVICE_ROLE_KEY",
      "SUPABASE_ANON_KEY",
      "WRAPPER_SECRET_KEY",
    ]

    crm = [
      "DATABASE_URL",
      "MIGRATION_DATABASE_URL", # privileged (migrator role) — one-off migrate task only; app uses least-privilege DATABASE_URL
      "SENTRY_DSN",
      "JWT_SECRET",
      "JWT_SECRET_PREVIOUS",
      "WRAPPER_SERVICE_TOKEN",
      "FA_JWT_SECRET",
      "BREVO_API_KEY",
      "BREVO_WEBHOOK_SECRET",
      "BREVO_SENDER_EMAIL", # FROM address for all CRM email; unset = Brevo rejects every send
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
      "MIGRATION_DATABASE_URL", # privileged (migrator role) — one-off migrate task only; app uses least-privilege DATABASE_URL
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
  }
}

# One Secrets Manager secret per suite app (wrapper | crm | fa).
resource "aws_secretsmanager_secret" "app" {
  for_each = local.apps

  name                    = "${var.project}/${var.environment}/${each.key}"
  description             = "Runtime secrets for the ${each.key} backend (populate before pods start; synced via External Secrets Operator)."
  recovery_window_in_days = 7

  tags = {
    Name = "${local.name_prefix}-${each.key}-secrets"
    App  = each.key
  }
}

# Placeholder secret version: a JSON object whose keys are the app's secret
# env-var names, each set to "REPLACE_ME". Operators overwrite the real values
# out-of-band; ignore_changes keeps Terraform from reverting them.
resource "aws_secretsmanager_secret_version" "app" {
  for_each = local.apps

  secret_id     = aws_secretsmanager_secret.app[each.key].id
  secret_string = jsonencode({ for k in local.app_secret_keys[each.key] : k => "REPLACE_ME" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
