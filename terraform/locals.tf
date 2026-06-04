# ---------------------------------------------------------------------------
# Shared locals — the single source of truth referenced by every other .tf file
# and exported (via outputs.tf) into the Helm values. Resource naming convention:
#   "${local.name_prefix}-<resource>"   e.g. zopkit-prod-wrapper-events
# ---------------------------------------------------------------------------
locals {
  name_prefix = "${var.project}-${var.environment}" # e.g. zopkit-prod
  account_id  = data.aws_caller_identity.current.account_id
  partition   = "aws"

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Stack       = "zopkit-suite"
  }

  # K8s namespace the workloads land in.
  namespace = "${var.project}-${var.environment}" # zopkit-prod

  # ----------------------------------------------------------------------------
  # PER-APP DEPLOYMENT CONTRACT (derived from the live code, not the migration
  # doc). port / health paths / start commands are authoritative.
  #
  # leader_safe = true  -> background jobs use Postgres pg_try_advisory_lock and
  #                        are safe on every pod; the web Deployment may scale + HPA.
  # leader_safe = false -> an UNGUARDED EventBridge outbox poller runs on every
  #                        pod (double-publishes under scale-out). web is pinned
  #                        to replicas=1 / HPA disabled until the poller is
  #                        leader-gated or split into a dedicated worker.
  # ----------------------------------------------------------------------------
  apps = {
    wrapper = {
      port               = 3000
      health_live        = "/health/live"
      health_ready       = "/health/ready"
      api_subdomain      = "api" # api.zopkit.com
      frontend_subdomain = "app" # app.zopkit.com (SPA on CloudFront)
      tenant_wildcard    = true  # *.zopkit.com tenant vanity -> wrapper
      leader_safe        = true  # pg advisory locks (0x57524b52, 8001, 719001, 7001-7003)
      websocket          = true  # /ws  (ALB stickiness required; pod-local registry)
      bus                = "sns" # publishes SNS inter-app-events + inter-app-broadcast
      ecr_repo           = "wrapper-backend"
      min_replicas       = 3
      max_replicas       = 10
    }
    crm = {
      port               = 4000
      health_live        = "/health"
      health_ready       = "/health"
      api_subdomain      = "crm-api" # crm-api.zopkit.com
      frontend_subdomain = "crm"     # crm.zopkit.com
      tenant_wildcard    = false
      leader_safe        = false # crmOutboxPoller: no leader election, no SKIP LOCKED -> single-leader only
      websocket          = false
      bus                = "sns" # publishes domain events to the business-events SNS topic
      ecr_repo           = "crm-backend"
      min_replicas       = 1 # PINNED: scaling out double-publishes business events (outbox poller, no leader election)
      max_replicas       = 1
    }
    fa = {
      port               = 3002 # NOT 5000 — SERVER_PORT default is 3002
      health_live        = "/api/health/health/live"
      health_ready       = "/api/health/health/ready"
      api_subdomain      = "accounting-api"
      frontend_subdomain = "accounting"
      tenant_wildcard    = false
      leader_safe        = false # faOutboxPoller + several setInterval crons run on every pod, no leader election
      websocket          = false
      bus                = "sns"
      ecr_repo           = "fa-backend"
      min_replicas       = 1 # PINNED: outbox poller + cron managers duplicate under scale-out
      max_replicas       = 1
    }
  }

  # ----------------------------------------------------------------------------
  # MESSAGING TOPOLOGY (two buses):
  #   1. Wrapper "platform bus"  = SNS (targeted + broadcast) -> per-app SQS.
  #   2. CRM/FA "business bus"   = EventBridge bus -> rules -> per-app SQS.
  # ----------------------------------------------------------------------------
  sns_topics = {
    inter_app_events    = "${local.name_prefix}-inter-app-events"    # targeted (wrapper platform bus)
    inter_app_broadcast = "${local.name_prefix}-inter-app-broadcast" # fanout (wrapper platform bus)
    business_events     = "${local.name_prefix}-business-events"     # CRM/FA domain events (replaces the EventBridge bus)
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

  # Route53 + ACM are defined in route53_acm.tf. These locals pin the addresses
  # so the rest of the stack can reference them regardless of create-vs-lookup.
  #   aws_route53_zone.this   (count = var.create_route53_zone ? 1 : 0)
  #   data.aws_route53_zone.this (count = var.create_route53_zone ? 0 : 1)
  #   aws_acm_certificate.wildcard   (DEFAULT provider / var.aws_region) -> ALB
  #   aws_acm_certificate.cloudfront (provider aws.us_east_1)            -> CloudFront
  route53_zone_id = var.create_route53_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.this[0].zone_id
  acm_cert_arn    = aws_acm_certificate_validation.wildcard.certificate_arn
}
