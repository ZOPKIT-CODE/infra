# ---------------------------------------------------------------------------
# Shared locals — the single source of truth referenced by every other .tf file.
# Resource naming convention: "${local.name_prefix}-<resource>"
#   e.g. zopkit-staging-wrapper-events
#
# This file MUST define every local the COPIED-VERBATIM files consume:
#   cognito.tf      -> local.apps (keys), local.fqdn[*].api/.frontend
#   messaging.tf    -> local.name_prefix, local.sns_topics, local.sqs_queues
#   s3.tf           -> local.s3_buckets, local.name_prefix
#   cloudfront.tf   -> local.frontends, local.s3_buckets
#   ecr.tf          -> local.name_prefix
#   secrets.tf      -> local.apps, local.name_prefix  (defines local.app_secret_keys itself)
# (ses_inbound.tf is NOT copied by default — optional CRM inbound email, off by
#  default; its eager filemd5() needs a deeper path from this stack. See Makefile.)
#
# It ALSO defines the richer ECS service contract (local.services, the 4-service
# expansion) plus the resolved per-service environment and secrets maps used by
# the ecs-service module.
# ---------------------------------------------------------------------------
locals {
  name_prefix = "${var.project}-${var.environment}" # e.g. zopkit-staging
  account_id  = data.aws_caller_identity.current.account_id
  partition   = "aws"

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Stack       = "zopkit-suite-ecs"
  }

  # ----------------------------------------------------------------------------
  # apps : keyed EXACTLY wrapper | crm | fa for compatibility with the copied
  # verbatim cognito.tf / secrets.tf / messaging.tf. cognito.tf consumes only the
  # map KEYS + local.fqdn[*].api/.frontend, so this slim contract is sufficient.
  # The richer ECS service contract (4 services incl. fa-consumer) is the SEPARATE
  # local.services map below — keeping cognito.tf's for_each = local.apps at three.
  # ----------------------------------------------------------------------------
  apps = {
    wrapper = { ecr_repo = "wrapper-backend", port = 3000, api_subdomain = "api", frontend_subdomain = "app", tenant_wildcard = true }
    crm     = { ecr_repo = "crm-backend", port = 4000, api_subdomain = "crm-api", frontend_subdomain = "crm", tenant_wildcard = false }
    fa      = { ecr_repo = "fa-backend", port = 3002, api_subdomain = "accounting-api", frontend_subdomain = "accounting", tenant_wildcard = false }
  }

  # ----------------------------------------------------------------------------
  # services : the ECS service contract (4 Fargate services). `app` = which apps[]
  # key supplies the env/secrets/task-role. `role` = the task-role key (fa-consumer
  # reuses the fa role). fa-consumer is a headless worker (no port / no ALB) running
  # the SQS consumer runner; its env + secrets are identical to fa-web.
  #
  # host_header values are built from local.fqdn (defined further down) so this map
  # references locals declared later in the SAME locals block — valid in HCL.
  # ----------------------------------------------------------------------------
  services = {
    "wrapper-web" = {
      enabled                = true # deployed first
      app                    = "wrapper"
      role                   = "wrapper"
      ecr_repo               = "wrapper-backend"
      cpu                    = 512
      memory                 = 1024
      container_port         = 3000
      command                = []
      needs_alb              = true
      host_header            = local.fqdn["wrapper"].api
      health_check_path      = "/health"
      stickiness_enabled     = true # WebSocket /ws — ALB cookie stickiness required
      autoscaling_enabled    = true # leader-safe (pg advisory locks)
      desired_count          = 1
      min_count              = 1
      max_count              = 3
      listener_rule_priority = 10
    }
    "crm-web" = {
      enabled                = false # deployed gradually (flip to true when ready)
      app                    = "crm"
      role                   = "crm"
      ecr_repo               = "crm-backend"
      cpu                    = 512
      memory                 = 1024
      container_port         = 4000
      command                = []
      needs_alb              = true
      host_header            = local.fqdn["crm"].api
      health_check_path      = "/health"
      stickiness_enabled     = false
      autoscaling_enabled    = false # PINNED: crmOutboxPoller not leader-gated
      desired_count          = 1
      min_count              = 1
      max_count              = 1
      listener_rule_priority = 20
    }
    "fa-web" = {
      enabled                = false # deployed gradually (flip to true when ready)
      app                    = "fa"
      role                   = "fa"
      ecr_repo               = "fa-backend"
      cpu                    = 512
      memory                 = 1024
      container_port         = 3002
      command                = []
      needs_alb              = true
      host_header            = local.fqdn["fa"].api
      health_check_path      = "/api/health/health/live" # NOT the aggregate /api/health/health
      stickiness_enabled     = false
      autoscaling_enabled    = false # PINNED: faOutboxPoller + crons not leader-gated
      desired_count          = 1
      min_count              = 1
      max_count              = 1
      listener_rule_priority = 30
    }
    "fa-consumer" = {
      enabled                = false # deployed gradually (flip to true when ready)
      app                    = "fa"
      role                   = "fa"
      ecr_repo               = "fa-backend"
      cpu                    = 256
      memory                 = 512
      container_port         = null
      command                = ["node", "dist/scripts/accounting-sqs-consumer-runner.js"]
      needs_alb              = false
      host_header            = null
      health_check_path      = null
      stickiness_enabled     = false
      autoscaling_enabled    = false # idempotent worker, no ALB
      desired_count          = 1
      min_count              = 1
      max_count              = 1
      listener_rule_priority = null
    }
  }

  # ----------------------------------------------------------------------------
  # MESSAGING TOPOLOGY (two buses, both SNS -> SQS):
  #   1. Wrapper "platform bus"  = SNS (targeted + broadcast) -> per-app SQS.
  #   2. CRM/FA "business bus"   = SNS business-events topic -> per-app SQS
  #      (each queue filters out its own app's events via sourceSystem anything-but).
  # ----------------------------------------------------------------------------
  sns_topics = {
    inter_app_events    = "${local.name_prefix}-inter-app-events"    # targeted (wrapper platform bus)
    inter_app_broadcast = "${local.name_prefix}-inter-app-broadcast" # fanout (wrapper platform bus)
    business_events     = "${local.name_prefix}-business-events"     # CRM/FA domain events business bus
  }

  # SQS queues: name => { app target, dlq?, source, filter_target }
  #   source = sns          → subscribes to inter_app_events (targeted on filter_target) + inter_app_broadcast
  #   source = sns_business → subscribes to business_events (filtered to exclude its own app's events)
  #   source = direct       → written to directly by the producer (no SNS subscription)
  sqs_queues = {
    wrapper_events          = { app = "wrapper", dlq = true, source = "sns", filter_target = "wrapper" }
    notifications_immediate = { app = "wrapper", dlq = true, source = "direct", filter_target = "" }
    notifications_bulk      = { app = "wrapper", dlq = true, source = "direct", filter_target = "" }
    notifications_scheduled = { app = "wrapper", dlq = true, source = "direct", filter_target = "" }
    crm_events              = { app = "crm", dlq = true, source = "sns", filter_target = "crm" }
    accounting_events       = { app = "fa", dlq = true, source = "sns", filter_target = "accounting" }
    business_events_crm     = { app = "crm", dlq = true, source = "sns_business", filter_target = "" }
    business_events_fa      = { app = "fa", dlq = true, source = "sns_business", filter_target = "" }
  }

  # S3 buckets. Frontend buckets are private (served via CloudFront OAC).
  s3_buckets = {
    claim_check     = { name = "${local.name_prefix}-platform-bus-claim-check", region = var.aws_region, public = false }
    wrapper_logos   = { name = "${local.name_prefix}-wrapper-logos", region = var.aws_region, public = false }
    crm_attachments = { name = "${local.name_prefix}-crm-attachments", region = var.data_region, public = false }
    fa_receipts     = { name = "${local.name_prefix}-fa-expense-receipts", region = var.data_region, public = false }
    ses_inbound     = { name = "${local.name_prefix}-crm-ses-inbound", region = var.aws_region, public = false }
    fe_wrapper      = { name = "${local.name_prefix}-wrapper-fe", region = var.aws_region, public = false }
    fe_crm          = { name = "${local.name_prefix}-crm-fe", region = var.aws_region, public = false }
    fe_fa           = { name = "${local.name_prefix}-fa-fe", region = var.aws_region, public = false }
  }

  # Frontend SPA distributions: subdomain => bucket key in local.s3_buckets
  frontends = {
    wrapper = { subdomain = "app", bucket = "fe_wrapper" }
    crm     = { subdomain = "crm", bucket = "fe_crm" }
    fa      = { subdomain = "accounting", bucket = "fe_fa" }
  }

  fqdn = {
    for k, a in local.apps : k => {
      api      = "${a.api_subdomain}.${var.root_domain}"
      frontend = "${a.frontend_subdomain}.${var.root_domain}"
    }
  }

  # An app is "live" when its <app>-web service is enabled (i.e. it has a prod
  # backend + frontend). When dns_only_live_apps=true, the apex DNS records are
  # created ONLY for live apps, so a partial-rollout env (e.g. prod with only
  # wrapper deployed) never points crm./accounting. records at empty resources or
  # clobbers another app's existing DNS. Default false preserves all-apps behavior.
  live_apps      = var.dns_only_live_apps ? { for k, v in local.apps : k => v if try(local.services["${k}-web"].enabled, false) } : local.apps
  live_frontends = var.dns_only_live_apps ? { for k, v in local.frontends : k => v if try(local.services["${k}-web"].enabled, false) } : local.frontends

  # Route53 + ACM are defined in route53_acm.tf. These locals pin the addresses
  # so the rest of the stack can reference them regardless of create-vs-lookup.
  #   aws_route53_zone.this   (count = var.create_route53_zone ? 1 : 0)
  #   data.aws_route53_zone.this (count = var.create_route53_zone ? 0 : 1)
  #   aws_acm_certificate.wildcard   (DEFAULT provider / var.aws_region) -> ALB
  #   aws_acm_certificate.cloudfront (provider aws.us_east_1)            -> CloudFront
  route53_zone_id = var.create_route53_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.this[0].zone_id
  acm_cert_arn    = aws_acm_certificate_validation.wildcard.certificate_arn

  # ----------------------------------------------------------------------------
  # PER-APP ENVIRONMENT (non-secret). Ported from the EKS stack's
  # outputs.tf app_wiring.env, resolved to ECS terms. fa-consumer reuses the fa
  # env (same `app` key). All values are strings.
  # ----------------------------------------------------------------------------
  # Cognito: reuse an EXISTING shared pool (with Google federation etc. already
  # configured) when overrides are set; otherwise fall back to the pool this stack
  # creates. Per-app client id via var.cognito_client_ids[app].
  cognito_pool_id     = var.cognito_user_pool_id != "" ? var.cognito_user_pool_id : aws_cognito_user_pool.this.id
  cognito_domain_name = var.cognito_existing_domain_prefix != "" ? var.cognito_existing_domain_prefix : aws_cognito_user_pool_domain.this.domain

  service_env_common = {
    for app, cfg in local.apps : app => {
      NODE_ENV                    = "production"
      # Honest telemetry labels: NODE_ENV is 'production' in BOTH envs' images,
      # which filed staging's Sentry events under environment:production.
      # Backends read SENTRY_ENVIRONMENT first (PR #28).
      SENTRY_ENVIRONMENT          = var.environment
      BYPASS_TRIAL_RESTRICTIONS   = tostring(var.bypass_trial_restrictions)
      AWS_REGION                  = var.aws_region
      COGNITO_REGION              = var.aws_region
      COGNITO_USER_POOL_ID        = local.cognito_pool_id
      COGNITO_CLIENT_ID           = lookup(var.cognito_client_ids, app, aws_cognito_user_pool_client.clients[app].id)
      COGNITO_ISSUER_URL          = "https://cognito-idp.${var.aws_region}.amazonaws.com/${local.cognito_pool_id}"
      COGNITO_DOMAIN              = "https://${local.cognito_domain_name}.auth.${var.aws_region}.amazoncognito.com"
      BASE_DOMAIN                 = var.root_domain
      REDIS_ENABLED               = "true"
      BACKEND_URL                 = "https://${local.fqdn[app].api}"
      FRONTEND_URL                = "https://${local.fqdn[app].frontend}"
      COGNITO_REDIRECT_URI        = "https://${local.fqdn[app].api}/api/auth/callback"
      COGNITO_LOGOUT_REDIRECT_URI = "https://${local.fqdn[app].frontend}"
    }
  }

  service_env = {
    wrapper = merge(local.service_env_common["wrapper"], {
      PORT                            = "3000"
      FRONTEND_URL                    = "https://${local.fqdn["wrapper"].frontend}"
      AWS_HOSTED_ZONE_ID              = local.route53_zone_id
      SNS_INTER_APP_TOPIC_ARN         = aws_sns_topic.topics["inter_app_events"].arn
      SNS_BROADCAST_TOPIC_ARN         = aws_sns_topic.topics["inter_app_broadcast"].arn
      SQS_WRAPPER_QUEUE_URL           = aws_sqs_queue.main["wrapper_events"].url
      SQS_NOTIFICATIONS_IMMEDIATE_URL = aws_sqs_queue.main["notifications_immediate"].url
      SQS_NOTIFICATIONS_BULK_URL      = aws_sqs_queue.main["notifications_bulk"].url
      SQS_NOTIFICATIONS_SCHEDULED_URL = aws_sqs_queue.main["notifications_scheduled"].url
      SNS_LARGE_PAYLOAD_BUCKET        = aws_s3_bucket.buckets["claim_check"].id
      S3_LOGO_BUCKET                  = var.logo_bucket_override != "" ? var.logo_bucket_override : aws_s3_bucket.buckets["wrapper_logos"].id
      CRM_APP_URL                     = "https://${local.fqdn["crm"].frontend}"
      ACCOUNTING_APP_URL              = "https://${local.fqdn["fa"].frontend}"
    })
    crm = merge(local.service_env_common["crm"], {
      PORT                   = "4000"
      SQS_INBOUND_QUEUE_URL  = aws_sqs_queue.main["crm_events"].url
      SQS_INBOUND_REGION     = var.aws_region
      AWS_S3_BUCKET_NAME     = aws_s3_bucket.buckets["crm_attachments"].id
      SNS_BUSINESS_TOPIC_ARN = aws_sns_topic.topics["business_events"].arn
      WRAPPER_API_URL        = "https://${local.fqdn["wrapper"].api}"
      CORS_ORIGINS           = "https://${local.fqdn["crm"].frontend}"
    })
    fa = merge(local.service_env_common["fa"], {
      SERVER_PORT                   = "3002"
      PORT                          = "3002"
      SQS_ACCOUNTING_QUEUE_URL      = aws_sqs_queue.main["accounting_events"].url
      SQS_BUSINESS_EVENTS_QUEUE_URL = aws_sqs_queue.main["business_events_fa"].url
      SQS_ACCOUNTING_DLQ_URL        = aws_sqs_queue.dlq["accounting_events"].url
      SNS_BUSINESS_TOPIC_ARN        = aws_sns_topic.topics["business_events"].arn
      S3_RECEIPTS_BUCKET            = aws_s3_bucket.buckets["fa_receipts"].id
      WRAPPER_API_URL               = "https://${local.fqdn["wrapper"].api}"
      CORS_ORIGINS                  = "https://${local.fqdn["fa"].frontend}"
    })
  }

  # ----------------------------------------------------------------------------
  # SECRETS injection (per app). Source ARNs:
  #   - app secret  : aws_secretsmanager_secret.app[<app>].arn (keys = local.app_secret_keys[<app>], defined in secrets.tf)
  #   - valkey secret: aws_secretsmanager_secret.valkey.arn   (we inject only REDIS_URL + REDIS_PASSWORD)
  #
  # DEDUP RULE: injected keys = (app_secret_keys[app] ∪ {REDIS_URL,REDIS_PASSWORD})
  #             MINUS keys(service_env[app]). A key MUST NOT appear in both the
  #             'environment' and 'secrets' blocks (ECS rejects duplicates). This
  #             drops e.g. fa's CORS_ORIGINS (it lives in env) from its secrets.
  # ----------------------------------------------------------------------------
  valkey_secret_keys = ["REDIS_URL", "REDIS_PASSWORD"]

  service_secret_keys = {
    for app, cfg in local.apps : app => [
      for k in distinct(concat(local.app_secret_keys[app], local.valkey_secret_keys)) :
      k if !contains(keys(local.service_env[app]), k)
    ]
  }

  # valueFrom strings: app keys -> app secret ARN; valkey keys -> valkey secret ARN.
  # Format "<secret-arn>:<KEY>::" extracts the JSON key with no version-stage/id pin.
  service_secrets = {
    for app, cfg in local.apps : app => {
      for k in local.service_secret_keys[app] : k => (
        contains(local.valkey_secret_keys, k)
        ? "${aws_secretsmanager_secret.valkey.arn}:${k}::"
        : "${aws_secretsmanager_secret.app[app].arn}:${k}::"
      )
    }
  }
}
