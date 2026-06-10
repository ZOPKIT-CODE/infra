# ---------------------------------------------------------------------------
# Outputs. These also PIN the resource addresses the leaf .tf files must use
# (so the foundation and the leaf modules stay consistent). The `app_wiring`
# output is consumed to render the Helm values (see README "Render values").
# ---------------------------------------------------------------------------

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.aws_region
}

output "namespace" {
  value = local.namespace
}

output "configure_kubectl" {
  description = "Run this to talk to the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

# --- Container registry ---
output "ecr_repository_urls" {
  description = "ECR repo URLs keyed by repo name."
  value       = { for k, r in aws_ecr_repository.repos : k => r.repository_url }
}

# --- Messaging ---
output "sns_topic_arns" {
  value = { for k, t in aws_sns_topic.topics : k => t.arn }
}

output "sqs_queue_urls" {
  value = { for k, q in aws_sqs_queue.main : k => q.url }
}

output "sqs_dlq_urls" {
  value = { for k, q in aws_sqs_queue.dlq : k => q.url }
}

output "business_events_topic_arn" {
  value = aws_sns_topic.topics["business_events"].arn
}

# --- Cache ---
output "valkey_primary_endpoint" {
  value = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "valkey_secret_arn" {
  description = "Secrets Manager ARN holding the Valkey AUTH token + rediss:// URL."
  value       = aws_secretsmanager_secret.valkey.arn
}

output "valkey_secret_name" {
  description = "Secrets Manager NAME of the Valkey secret (ESO remoteRef key for REDIS_URL/REDIS_PASSWORD)."
  value       = aws_secretsmanager_secret.valkey.name
}

# ALB Ingress TLS cert (primary-region wildcard). Consumed by render-values.sh ->
# Helm ingress.certArn. Without this, the rendered Ingress has no certificate-arn.
output "acm_cert_arn" {
  description = "Primary-region wildcard ACM cert ARN for the shared ALB."
  value       = local.acm_cert_arn
}

# --- Cognito ---
output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_user_pool_client_ids" {
  value = { for k, c in aws_cognito_user_pool_client.clients : k => c.id }
}

output "cognito_domain" {
  value = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "cognito_issuer_url" {
  value = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
}

output "cognito_platform_admin_group" {
  description = "Cognito group name for internal platform admins (cross-tenant plane)."
  value       = aws_cognito_user_group.platform_admins.name
}

# --- Storage / CDN ---
output "s3_bucket_names" {
  value = { for k, b in aws_s3_bucket.buckets : k => b.id }
}

output "cloudfront_domains" {
  description = "CloudFront distribution domains keyed by app (point the frontend DNS here)."
  value       = { for k, d in aws_cloudfront_distribution.frontends : k => d.domain_name }
}

# --- Secrets (containers; values filled out-of-band) ---
output "app_secret_arns" {
  value = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
}

# --- IRSA roles per app ---
output "app_irsa_role_arns" {
  value = { for k, r in aws_iam_role.app : k => r.arn }
}

# ---------------------------------------------------------------------------
# Consolidated per-app wiring for Helm. `terraform output -json app_wiring`
# yields everything the chart needs to template a backend (non-secret config +
# resource ARNs/URLs/IDs). Secrets themselves come from Secrets Manager via ESO.
# ---------------------------------------------------------------------------
output "app_wiring" {
  value = {
    for app, cfg in local.apps : app => {
      image           = aws_ecr_repository.repos[cfg.ecr_repo].repository_url
      port            = cfg.port
      health_live     = cfg.health_live
      health_ready    = cfg.health_ready
      api_host        = local.fqdn[app].api
      frontend_host   = local.fqdn[app].frontend
      irsa_role_arn   = aws_iam_role.app[app].arn
      secret_arn      = aws_secretsmanager_secret.app[app].arn
      min_replicas    = cfg.min_replicas
      max_replicas    = cfg.max_replicas
      leader_safe     = cfg.leader_safe
      websocket       = cfg.websocket
      tenant_wildcard = cfg.tenant_wildcard

      env = merge(
        {
          NODE_ENV             = "production"
          AWS_REGION           = var.aws_region
          COGNITO_REGION       = var.aws_region
          COGNITO_USER_POOL_ID = aws_cognito_user_pool.this.id
          COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.clients[app].id
          COGNITO_ISSUER_URL   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
          COGNITO_DOMAIN       = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.aws_region}.amazoncognito.com"
          # Platform-admin plane: backend reads this group from the cognito:groups claim.
          COGNITO_PLATFORM_ADMIN_GROUP = aws_cognito_user_group.platform_admins.name
          BASE_DOMAIN                  = var.root_domain
          REDIS_ENABLED                = "true"
          # Backend-mediated OAuth: BACKEND_URL drives the redirect_uri the app sends to
          # Cognito on both /authorize and /oauth2/token, and must match a registered
          # callback (the API host) exactly. FRONTEND_URL is the SPA origin (CORS/return).
          BACKEND_URL                 = "https://${local.fqdn[app].api}"
          FRONTEND_URL                = "https://${local.fqdn[app].frontend}"
          COGNITO_REDIRECT_URI        = "https://${local.fqdn[app].api}/api/auth/callback"
          COGNITO_LOGOUT_REDIRECT_URI = "https://${local.fqdn[app].frontend}"
        },
        app == "wrapper" ? {
          PORT                            = tostring(cfg.port)
          FRONTEND_URL                    = "https://${local.fqdn["wrapper"].frontend}"
          AWS_HOSTED_ZONE_ID              = local.route53_zone_id
          SNS_INTER_APP_TOPIC_ARN         = aws_sns_topic.topics["inter_app_events"].arn
          SNS_BROADCAST_TOPIC_ARN         = aws_sns_topic.topics["inter_app_broadcast"].arn
          SQS_WRAPPER_QUEUE_URL           = aws_sqs_queue.main["wrapper_events"].url
          SQS_NOTIFICATIONS_IMMEDIATE_URL = aws_sqs_queue.main["notifications_immediate"].url
          SQS_NOTIFICATIONS_BULK_URL      = aws_sqs_queue.main["notifications_bulk"].url
          SQS_NOTIFICATIONS_SCHEDULED_URL = aws_sqs_queue.main["notifications_scheduled"].url
          SNS_LARGE_PAYLOAD_BUCKET        = aws_s3_bucket.buckets["claim_check"].id
          S3_LOGO_BUCKET                  = aws_s3_bucket.buckets["wrapper_logos"].id
          CRM_APP_URL                     = "https://${local.fqdn["crm"].frontend}"
          ACCOUNTING_APP_URL              = "https://${local.fqdn["fa"].frontend}"
        } : {},
        app == "crm" ? {
          PORT                   = tostring(cfg.port)
          SQS_INBOUND_QUEUE_URL  = aws_sqs_queue.main["crm_events"].url
          SQS_INBOUND_REGION     = var.aws_region
          AWS_S3_BUCKET_NAME     = aws_s3_bucket.buckets["crm_attachments"].id
          SNS_BUSINESS_TOPIC_ARN = aws_sns_topic.topics["business_events"].arn
          WRAPPER_API_URL        = "https://${local.fqdn["wrapper"].api}"
          CORS_ORIGINS           = "https://${local.fqdn["crm"].frontend}"
        } : {},
        app == "fa" ? {
          SERVER_PORT                   = tostring(cfg.port)
          PORT                          = tostring(cfg.port)
          SQS_ACCOUNTING_QUEUE_URL      = aws_sqs_queue.main["accounting_events"].url
          SQS_BUSINESS_EVENTS_QUEUE_URL = aws_sqs_queue.main["business_events_fa"].url
          SQS_ACCOUNTING_DLQ_URL        = aws_sqs_queue.dlq["accounting_events"].url
          SNS_BUSINESS_TOPIC_ARN        = aws_sns_topic.topics["business_events"].arn
          S3_RECEIPTS_BUCKET            = aws_s3_bucket.buckets["fa_receipts"].id
          WRAPPER_API_URL               = "https://${local.fqdn["wrapper"].api}"
          CORS_ORIGINS                  = "https://${local.fqdn["fa"].frontend}"
        } : {},
      )
    }
  }
}
