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
    wrapper = { ecr_repo = "wrapper-backend", port = 3000, api_subdomain = "api", frontend_subdomain = "app", tenant_wildcard = true, cdn_proxies_api = false, cognito_client = true, manage_dns = true }
    crm     = { ecr_repo = "crm-backend", port = 4000, api_subdomain = "crm-api", frontend_subdomain = "crm", tenant_wildcard = false, cdn_proxies_api = false, cognito_client = true, manage_dns = true }
    fa      = { ecr_repo = "fa-backend", port = 3002, api_subdomain = "accounting-api", frontend_subdomain = "accounting", tenant_wildcard = false, cdn_proxies_api = false, cognito_client = true, manage_dns = true }
    # lens's frontend does bare relative fetch("/api/...") calls with no configurable API base
    # URL (unlike wrapper/crm/fa) - it MUST be same-origin, so its CloudFront distribution needs
    # to proxy /api/* to the backend ALB. wrapper/crm/fa are deliberately left false: unclear
    # whether their frontends rely on this and untested here - don't change their live behavior.
    lens    = { ecr_repo = "lens-backend", port = 3002, api_subdomain = "lens-api", frontend_subdomain = "lens", tenant_wildcard = false, cdn_proxies_api = true, cognito_client = true, manage_dns = true }
    # Academy was stood up out-of-band and is being adopted, not created: its ECS
    # service, task role, secret, log group, ECR repo and target group all already
    # exist and are imported. Its API host is academy-api.<root>; the frontend is a
    # CloudFront distribution this stack does not manage, so academy is deliberately
    # NOT in local.frontends.
    academy = { ecr_repo = "academy-backend", port = 8000, api_subdomain = "academy-api", frontend_subdomain = "academy-dev", tenant_wildcard = false, cdn_proxies_api = false, cognito_client = false, manage_dns = true }
    # Entertainment ERP: adopted from an out-of-band deployment. It answers on PROD
    # hostnames (entertainment-api.zopkit.com / entertainment.zopkit.com) while running
    # on the STAGING ALB, and its Route53 records live in the zopkit.com zone, so
    # manage_dns = false — deriving <api_subdomain>.<root_domain> here would create a
    # bogus entertainment-api.staging.zopkit.com record that routes nowhere.
    entertainment-erp = { ecr_repo = "entertainment-erp-backend", port = 8080, api_subdomain = "entertainment-api", frontend_subdomain = "entertainment", tenant_wildcard = false, cdn_proxies_api = false, cognito_client = false, manage_dns = false }
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
  services_all = {
    "wrapper-web" = {
      enabled                = true # deployed first
      app                    = "wrapper"
      role                   = "wrapper"
      ecr_repo               = "wrapper-backend"
      cpu                    = 512
      memory                 = 1024
      container_port         = 3000
      command                = []
      extra_env              = {}
      needs_alb              = true
      host_header            = local.fqdn["wrapper"].api
      health_check_path      = "/health"
      stickiness_enabled     = true # WebSocket /ws — ALB cookie stickiness required
      autoscaling_enabled    = true # leader-safe (pg advisory locks)
      desired_count          = 1
      min_count              = 1
      max_count              = 3
      listener_rule_priority = 10
      health_check_grace_period_seconds = 60
    }
    "crm-web" = {
      enabled                = true # live in staging AND prod (crm.zopkit.com cut over 2026-06-11)
      app                    = "crm"
      role                   = "crm"
      ecr_repo               = "crm-backend"
      cpu                    = 512
      memory                 = 1024
      container_port         = 4000
      command                = []
      # PROCESS_ROLE is set but READ BY NOTHING: b2b-crm's server.ts starts the
      # Platform Bus SQS consumer, crmOutboxPoller, the DLQ drain, invitation-sync
      # and the crons unconditionally, in every process. (server/src/app.ts:632
      # describes a "PROCESS_ROLE gate" that was never implemented.) So this task
      # runs the full background machinery, not just the API.
      extra_env              = { PROCESS_ROLE = "web" }
      needs_alb              = true
      host_header            = local.fqdn["crm"].api
      health_check_path      = "/health"
      stickiness_enabled     = false
      # PINNED. This previously read `autoscaling_enabled = true # UNPINNED:
      # outbox poller + SQS consumer moved to crm-worker` — a false premise, see
      # above: nothing moved. A 2nd task means two SQS consumers on one queue and
      # two outbox pollers (which have no SKIP-LOCKED claim). That duplicate
      # consumption is the 2026-06-11 incident where a 4-copy tenant.onboarded
      # batch drove concurrent bootstraps and corrupted a tenant's layouts.
      # Unpin only after CRM leader-gates its pollers the way wrapper does
      # (pg_try_advisory_lock).
      autoscaling_enabled    = false
      desired_count          = 1
      min_count              = 1
      max_count              = 1
      listener_rule_priority = 20
      health_check_grace_period_seconds = 60
    }
    "crm-worker" = {
      enabled                = true
      app                    = "crm"
      role                   = "crm"
      ecr_repo               = "crm-backend"
      cpu                    = 512
      memory                 = 1024
      container_port         = null
      command                = []
      # DO NOT RUN THIS ALONGSIDE crm-web. Same image, no command override, and
      # PROCESS_ROLE is read by nothing — so this is a second full copy of every
      # consumer/poller crm-web already runs, not a complement to it. It is
      # absent in staging and desired_count=0 in prod; both are correct today.
      # It becomes meaningful only once b2b-crm actually implements the role gate.
      extra_env              = { PROCESS_ROLE = "worker" }
      needs_alb              = false
      host_header            = null
      health_check_path      = null
      stickiness_enabled     = false
      autoscaling_enabled    = false # PINNED: outbox poller has no SKIP-LOCKED claim — exactly one worker
      desired_count          = 1
      min_count              = 1
      max_count              = 1
      listener_rule_priority = null
      health_check_grace_period_seconds = 60
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
      extra_env              = {}
      needs_alb              = true
      host_header            = local.fqdn["fa"].api
      health_check_path      = "/api/health/health/live" # NOT the aggregate /api/health/health
      stickiness_enabled     = false
      autoscaling_enabled    = false # PINNED: faOutboxPoller + crons not leader-gated
      desired_count          = 1
      min_count              = 1
      max_count              = 1
      listener_rule_priority = 30
      health_check_grace_period_seconds = 60
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
      extra_env              = {}
      needs_alb              = false
      host_header            = null
      health_check_path      = null
      stickiness_enabled     = false
      autoscaling_enabled    = false # idempotent worker, no ALB
      desired_count          = 1
      min_count              = 1
      max_count              = 1
      listener_rule_priority = null
      health_check_grace_period_seconds = 60
    }
    "lens-web" = {
      enabled                = true # image pushed to ECR; running in dev-auth mode (no Kinde app registered yet)
      app                    = "lens"
      role                   = "lens"
      ecr_repo               = "lens-backend"
      cpu                    = 512
      memory                 = 1024
      container_port         = 3002
      command                = []
      extra_env              = {}
      needs_alb              = true
      host_header            = local.fqdn["lens"].api
      health_check_path      = "/api/health" # NOT /api/health/ready — that pings the DB and flaps the target group
      stickiness_enabled     = false
      autoscaling_enabled    = true
      desired_count          = 1
      min_count              = 1
      max_count              = 3
      listener_rule_priority = 40
      # Supabase project is in ap-northeast-1; the RBAC-bootstrap query sequence on cold
      # start over that cross-region link takes ~100s, well past the shared 60s default.
      health_check_grace_period_seconds = 240
    }
    # ⚠ EXTERNALLY DEPLOYED — terraform does NOT own this service's running revision.
    # academy ships from .github/workflows/deploy-dev-ecs.yml on its `dev` branch,
    # which registers a task definition and calls update-service directly. Terraform
    # tracks the surrounding infrastructure (target group, listener rule, log group,
    # task role, secret, ECR repo) but its aws_ecs_service.task_definition will drift
    # to whatever that pipeline last shipped.
    #
    # DO NOT `terraform apply` this service without checking the plan first: an apply
    # sets task_definition back to the revision terraform knows, rolling the app back
    # to an older image. The proper fix is ignore_changes = [task_definition], which
    # needs a module change because ignore_changes cannot be driven by a variable.
    "academy-web" = {
      enabled                = true # adopted from an out-of-band deployment (see local.apps)
      app                    = "academy"
      role                   = "academy"
      ecr_repo               = "academy-backend"
      cpu                    = 512
      memory                 = 1024
      container_port         = 8000
      command                = []
      extra_env              = {}
      needs_alb              = true
      host_header            = local.fqdn["academy"].api
      health_check_path      = "/health"
      stickiness_enabled     = false
      # Adopt the pre-existing group name (...-academy-tg) instead of the generated
      # ...-academy-web, so the import is not a replacement.
      target_group_name      = "${local.name_prefix}-academy-tg"
      autoscaling_enabled    = false # single task, like every other app whose pollers are not leader-gated
      desired_count          = 1
      min_count              = 1
      max_count              = 1
      listener_rule_priority = 100 # matches the live rule
      health_check_grace_period_seconds = 60
    }
    # ⚠ EXTERNALLY DEPLOYED — same caveat as academy-web above. ERP has no deploy
    # workflow at all; it is released by hand through the Deployment-Manager IAM user,
    # so terraform's view of its running revision goes stale the moment anyone deploys.
    "entertainment-erp-web" = {
      enabled                = true # adopted from an out-of-band deployment (see local.apps)
      app                    = "entertainment-erp"
      role                   = "entertainment-erp"
      ecr_repo               = "entertainment-erp-backend"
      cpu                    = 512
      memory                 = 1024
      container_port         = 8080
      command                = []
      extra_env              = {}
      needs_alb              = true
      # LITERAL prod hostnames, not local.fqdn: this service is reached on
      # entertainment-api.zopkit.com even though it runs on the staging ALB, and the
      # staging-derived name (entertainment-api.staging.zopkit.com) 404s. One service
      # serves both the API and the SPA, hence the second header.
      host_header            = "entertainment-api.zopkit.com"
      extra_host_headers     = ["entertainment.zopkit.com"]
      health_check_path      = "/health"
      stickiness_enabled     = false
      autoscaling_enabled    = false # single task; no evidence its pollers are leader-gated
      desired_count          = 1
      min_count              = 1
      max_count              = 1
      listener_rule_priority = 110 # matches the live rule
      health_check_grace_period_seconds = 60
    }
  }

  # The effective service map. services_all above carries ONE `enabled` flag per
  # service, shared by every workspace; var.service_enabled_overrides re-resolves
  # it per environment. Applied here rather than at each call site so every
  # consumer (the service module, the deployed-tag SSM data source, live_apps)
  # sees the same answer.
  services = {
    for k, v in local.services_all : k => merge(v, {
      enabled = try(var.service_enabled_overrides[k], v.enabled)
    })
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
    fe_lens         = { name = "${local.name_prefix}-lens-fe", region = var.aws_region, public = false }
  }

  # Frontend SPA distributions: subdomain => bucket key in local.s3_buckets.
  # var.disabled_frontends drops entries per environment (an app can have a
  # frontend in prod and none in staging).
  frontends_all = {
    wrapper = { subdomain = "app", bucket = "fe_wrapper" }
    crm     = { subdomain = "crm", bucket = "fe_crm" }
    fa      = { subdomain = "accounting", bucket = "fe_fa" }
    lens    = { subdomain = "lens", bucket = "fe_lens" }
  }
  frontends = { for k, v in local.frontends_all : k => v if !contains(var.disabled_frontends, k) }

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
  live_apps      = { for k, v in (var.dns_only_live_apps ? { for k2, v2 in local.apps : k2 => v2 if try(local.services["${k2}-web"].enabled, false) } : local.apps) : k => v if v.manage_dns }
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
  # PER-APP ENVIRONMENT (non-secret). fa-consumer reuses the fa env (same `app`
  # key). All values are strings.
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
      # Backends read SENTRY_ENVIRONMENT first (wrapper PR #28; crm/fa to follow).
      SENTRY_ENVIRONMENT          = var.environment
      BYPASS_TRIAL_RESTRICTIONS   = tostring(var.bypass_trial_restrictions)
      AWS_REGION                  = var.aws_region
      BASE_DOMAIN                 = var.root_domain
      REDIS_ENABLED               = tostring(var.enable_valkey)
      BACKEND_URL                 = "https://${local.fqdn[app].api}"
      FRONTEND_URL                = "https://${local.fqdn[app].frontend}"
    }
  }

  # Cognito wiring, ONLY for apps that authenticate against the shared pool
  # (apps.<app>.cognito_client). Adopted apps can bring their own IdP — academy
  # uses Google OAuth + Supabase — and injecting COGNITO_CLIENT_ID for them would
  # force an app client to be created in the shared pool that nothing ever uses.
  service_env_cognito = {
    for app, cfg in local.apps : app => {
      COGNITO_REGION              = var.aws_region
      COGNITO_USER_POOL_ID        = local.cognito_pool_id
      COGNITO_CLIENT_ID           = lookup(var.cognito_client_ids, app, aws_cognito_user_pool_client.clients[app].id)
      COGNITO_ISSUER_URL          = "https://cognito-idp.${var.aws_region}.amazonaws.com/${local.cognito_pool_id}"
      COGNITO_DOMAIN              = "https://${local.cognito_domain_name}.auth.${var.aws_region}.amazoncognito.com"
      COGNITO_REDIRECT_URI        = "https://${local.fqdn[app].api}/api/auth/callback"
      COGNITO_LOGOUT_REDIRECT_URI = "https://${local.fqdn[app].frontend}"
    } if cfg.cognito_client
  }

  # What each app actually gets: the common block, plus Cognito only if opted in.
  app_env = {
    for app, cfg in local.apps : app => merge(
      local.service_env_common[app],
      try(local.service_env_cognito[app], {}),
    )
  }

  service_env = {
    wrapper = merge(local.app_env["wrapper"], {
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
      # Public blog crawler-HTML (blog-prerender.ts): siteOrigin/mediaOrigin for
      # og:url/og:image must resolve to the public marketing site + API domain,
      # not whatever Host header the request arrived with.
      BLOG_SITE_URL                   = "https://www.${var.root_domain}"
      BLOG_PUBLIC_BASE_URL            = "https://${local.fqdn["wrapper"].api}"
    })
    crm = merge(local.app_env["crm"], {
      PORT                   = "4000"
      SQS_INBOUND_QUEUE_URL  = aws_sqs_queue.main["crm_events"].url
      SQS_INBOUND_REGION     = var.aws_region
      AWS_S3_BUCKET_NAME     = aws_s3_bucket.buckets["crm_attachments"].id
      SNS_BUSINESS_TOPIC_ARN = aws_sns_topic.topics["business_events"].arn
      WRAPPER_API_URL        = "https://${local.fqdn["wrapper"].api}"
      CORS_ORIGINS           = "https://${local.fqdn["crm"].frontend}"
      # CRM's @fastify/cors reads CLIENT_URL (CORS_ORIGINS kept for forward-compat)
      CLIENT_URL             = "https://${local.fqdn["crm"].frontend}"
    })
    fa = merge(local.app_env["fa"], {
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
    # lens is a standalone app: SSO via the shared zopkit-platform Cognito pool (its own
    # confidential app client, provisioned out-of-band — see backend/docs/COGNITO-SSO.md
    # in the lens repo), own Stripe/Razorpay, no platform SNS/SQS bus. service_env_common's
    # COGNITO_*/REDIS_ENABLED keys are harmless-but-unused (lens's code never reads them) —
    # lens's own Cognito wiring (EXTERNAL_*) comes from its app secret, not from here.
    lens = merge(local.app_env["lens"], {
      SERVER_PORT                     = "3002"
      PORT                             = "3002"
      CORS_ORIGINS                     = "https://${local.fqdn["lens"].frontend}"
      PUBLIC_APP_ORIGIN                = "https://${local.fqdn["lens"].frontend}"
      APP_PUBLIC_URL                   = "https://${local.fqdn["lens"].frontend}"
      TENANT_RLS_ENABLED               = "true"
      TENANT_HOST_SUFFIX               = local.fqdn["lens"].frontend
      # Supabase's chain roots at their own "Supabase Root 2021 CA", not a publicly-trusted
      # one - true here only works together with DATABASE_SSL_CA (below, in the app secret)
      # pinning that root. Without it this crash-loops with SELF_SIGNED_CERT_IN_CHAIN
      # (verified directly). See lens backend db/index.ts for the driver-side half of this.
      DATABASE_SSL_REJECT_UNAUTHORIZED = "true"
      JWT_EXPIRES_IN                   = "8h"
      RATE_LIMIT_MAX                   = "2000"
      WORKFLOW_CRON_ENABLED            = "true"
      WORKFLOW_CRON_INTERVAL_MS        = "3600000"
      # Resend is checked first by default (email-config.ts) and RESEND_API_KEY still holds the
      # Terraform placeholder ("REPLACE_ME" — non-empty, so it reads as "configured"), so without
      # this override the app picks Resend and fails instead of using the real Brevo key.
      TRANSACTIONAL_EMAIL_PROVIDER     = "brevo"
      BREVO_FROM_EMAIL                 = "platformadmin@zopkit.com" # verified sender in Brevo
      BREVO_FROM_NAME                  = "Zopkit Lens"
      # Real Cognito app client is provisioned and verified (callback URLs + Managed Login
      # branding confirmed live). NODE_ENV=production is safe now — validate-production-env.ts
      # requires EXTERNAL_ISSUER_URL/EXTERNAL_OAUTH_DOMAIN/EXTERNAL_CLIENT_ID/EXTERNAL_CLIENT_SECRET
      # (from the app secret, see secrets.tf) and forbids ALLOW_DEV_AUTH in this mode.
      NODE_ENV = "production"
    })

    # Academy is ADOPTED, so this mirrors the environment its live task definition
    # already has. It authenticates with Google OAuth + Supabase, not Cognito, so
    # the COGNITO_* keys service_env_common contributes are inert for it.
    academy = merge(local.app_env["academy"], {
      HOST                      = "0.0.0.0"
      PORT                      = "8000"
      JWT_EXPIRES_IN            = "15m"
      REFRESH_TOKEN_EXPIRES_IN  = "7d"
      RATE_LIMIT_MAX            = "1000"
      RATE_LIMIT_WINDOW         = "1 minute"
      # Its SPA is served from academy-dev.<root> by a CloudFront distribution this
      # stack does not manage — hence frontend_subdomain = "academy-dev" in local.apps.
      CORS_ORIGIN               = "https://${local.fqdn["academy"].frontend}"
      GOOGLE_OAUTH_REDIRECT_URI = "https://${local.fqdn["academy"].api}/api/auth/google/callback"
    })

    # Entertainment ERP: adopted, so this mirrors its live task definition. CORS is
    # pinned to the literal prod hostname it is actually served on, not a derived one.
    entertainment-erp = merge(local.app_env["entertainment-erp"], {
      PORT                 = "8080"
      CORS_ORIGINS         = "https://entertainment.zopkit.com"
      ENABLE_RLS           = "false"
      REGISTRATION_ENABLED = "true"
      STORAGE_DRIVER       = "local"
      FILE_STORAGE_PATH    = "./uploads"
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
  # Empty when disabled: no app's task definition asks ECS to resolve a REDIS_URL/
  # REDIS_PASSWORD secret that no longer exists (would otherwise fail every future
  # task launch, not just lose caching).
  valkey_secret_keys = var.enable_valkey ? ["REDIS_URL", "REDIS_PASSWORD"] : []

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
        ? "${aws_secretsmanager_secret.valkey[0].arn}:${k}::"
        : "${aws_secretsmanager_secret.app[app].arn}:${k}::"
      )
    }
  }
}
