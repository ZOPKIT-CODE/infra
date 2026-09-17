locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  partition   = "aws"

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Stack       = "zopkit-suite-ecs"
  }

  apps = {
    wrapper           = { ecr_repo = "wrapper-backend", port = 3000, api_subdomain = "api", frontend_subdomain = "app", tenant_wildcard = true, cdn_proxies_api = false, cognito_client = true, manage_dns = true }
    crm               = { ecr_repo = "crm-backend", port = 4000, api_subdomain = "crm-api", frontend_subdomain = "crm", tenant_wildcard = false, cdn_proxies_api = false, cognito_client = true, manage_dns = true }
    fa                = { ecr_repo = "fa-backend", port = 3002, api_subdomain = "accounting-api", frontend_subdomain = "accounting", tenant_wildcard = false, cdn_proxies_api = false, cognito_client = true, manage_dns = true }
    lens              = { ecr_repo = "lens-backend", port = 3002, api_subdomain = "lens-api", frontend_subdomain = "lens", tenant_wildcard = false, cdn_proxies_api = true, cognito_client = true, manage_dns = true }
    academy           = { ecr_repo = "academy-backend", port = 8000, api_subdomain = "academy-api", frontend_subdomain = "academy-dev", tenant_wildcard = false, cdn_proxies_api = false, cognito_client = false, manage_dns = true }
    entertainment-erp = { ecr_repo = "entertainment-erp-backend", port = 8080, api_subdomain = "entertainment-api", frontend_subdomain = "entertainment", tenant_wildcard = false, cdn_proxies_api = false, cognito_client = false, manage_dns = false }
  }

  services_all = {
    "wrapper-web" = {
      enabled                           = true
      app                               = "wrapper"
      role                              = "wrapper"
      ecr_repo                          = "wrapper-backend"
      cpu                               = 512
      memory                            = 1024
      container_port                    = 3000
      command                           = []
      extra_env                         = {}
      needs_alb                         = true
      host_header                       = local.fqdn["wrapper"].api
      health_check_path                 = "/health"
      stickiness_enabled                = true
      autoscaling_enabled               = true
      desired_count                     = 1
      min_count                         = 1
      max_count                         = 3
      listener_rule_priority            = 10
      health_check_grace_period_seconds = 60
    }
    "crm-web" = {
      enabled                           = true
      app                               = "crm"
      role                              = "crm"
      ecr_repo                          = "crm-backend"
      cpu                               = 512
      memory                            = 1024
      container_port                    = 4000
      command                           = []
      extra_env                         = { PROCESS_ROLE = "web" }
      needs_alb                         = true
      host_header                       = local.fqdn["crm"].api
      health_check_path                 = "/health"
      stickiness_enabled                = false
      autoscaling_enabled               = false
      desired_count                     = 1
      min_count                         = 1
      max_count                         = 1
      listener_rule_priority            = 20
      health_check_grace_period_seconds = 60
    }
    "crm-worker" = {
      enabled                           = true
      app                               = "crm"
      role                              = "crm"
      ecr_repo                          = "crm-backend"
      cpu                               = 512
      memory                            = 1024
      container_port                    = null
      command                           = []
      extra_env                         = { PROCESS_ROLE = "worker" }
      needs_alb                         = false
      host_header                       = null
      health_check_path                 = null
      stickiness_enabled                = false
      autoscaling_enabled               = false
      desired_count                     = 1
      min_count                         = 1
      max_count                         = 1
      listener_rule_priority            = null
      health_check_grace_period_seconds = 60
    }
    "fa-web" = {
      enabled                           = false
      app                               = "fa"
      role                              = "fa"
      ecr_repo                          = "fa-backend"
      cpu                               = 512
      memory                            = 1024
      container_port                    = 3002
      command                           = []
      extra_env                         = {}
      needs_alb                         = true
      host_header                       = local.fqdn["fa"].api
      health_check_path                 = "/api/health/health/live"
      stickiness_enabled                = false
      autoscaling_enabled               = false
      desired_count                     = 1
      min_count                         = 1
      max_count                         = 1
      listener_rule_priority            = 30
      health_check_grace_period_seconds = 60
    }
    "fa-consumer" = {
      enabled                           = false
      app                               = "fa"
      role                              = "fa"
      ecr_repo                          = "fa-backend"
      cpu                               = 256
      memory                            = 512
      container_port                    = null
      command                           = ["node", "dist/scripts/accounting-sqs-consumer-runner.js"]
      extra_env                         = {}
      needs_alb                         = false
      host_header                       = null
      health_check_path                 = null
      stickiness_enabled                = false
      autoscaling_enabled               = false
      desired_count                     = 1
      min_count                         = 1
      max_count                         = 1
      listener_rule_priority            = null
      health_check_grace_period_seconds = 60
    }
    "lens-web" = {
      enabled                           = true
      app                               = "lens"
      role                              = "lens"
      ecr_repo                          = "lens-backend"
      cpu                               = 512
      memory                            = 1024
      container_port                    = 3002
      command                           = []
      extra_env                         = {}
      needs_alb                         = true
      host_header                       = local.fqdn["lens"].api
      health_check_path                 = "/api/health"
      stickiness_enabled                = false
      autoscaling_enabled               = true
      desired_count                     = 1
      min_count                         = 1
      max_count                         = 3
      listener_rule_priority            = 40
      health_check_grace_period_seconds = 240
    }
    "academy-web" = {
      enabled                           = true
      app                               = "academy"
      role                              = "academy"
      ecr_repo                          = "academy-backend"
      cpu                               = 512
      memory                            = 1024
      container_port                    = 8000
      command                           = []
      extra_env                         = {}
      needs_alb                         = true
      host_header                       = local.fqdn["academy"].api
      health_check_path                 = "/health"
      stickiness_enabled                = false
      target_group_name                 = "${local.name_prefix}-academy-tg"
      autoscaling_enabled               = false
      desired_count                     = 1
      min_count                         = 1
      max_count                         = 1
      listener_rule_priority            = 100
      health_check_grace_period_seconds = 60
    }
    "entertainment-erp-web" = {
      enabled                           = true
      app                               = "entertainment-erp"
      role                              = "entertainment-erp"
      ecr_repo                          = "entertainment-erp-backend"
      cpu                               = 512
      memory                            = 1024
      container_port                    = 8080
      command                           = []
      extra_env                         = {}
      needs_alb                         = true
      host_header                       = "entertainment-api.zopkit.com"
      extra_host_headers                = ["entertainment.zopkit.com"]
      health_check_path                 = "/health"
      stickiness_enabled                = false
      autoscaling_enabled               = false
      desired_count                     = 1
      min_count                         = 1
      max_count                         = 1
      listener_rule_priority            = 110
      health_check_grace_period_seconds = 60
    }
  }

  services = {
    for k, v in local.services_all : k => merge(v, {
      enabled = try(var.service_enabled_overrides[k], v.enabled)
    })
  }

  sns_topics = {
    inter_app_events    = "${local.name_prefix}-inter-app-events"
    inter_app_broadcast = "${local.name_prefix}-inter-app-broadcast"
    business_events     = "${local.name_prefix}-business-events"
  }

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

  live_apps      = { for k, v in(var.dns_only_live_apps ? { for k2, v2 in local.apps : k2 => v2 if try(local.services["${k2}-web"].enabled, false) } : local.apps) : k => v if v.manage_dns }
  live_frontends = var.dns_only_live_apps ? { for k, v in local.frontends : k => v if try(local.services["${k}-web"].enabled, false) } : local.frontends

  route53_zone_id = var.create_route53_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.this[0].zone_id
  acm_cert_arn    = aws_acm_certificate_validation.wildcard.certificate_arn

  cognito_pool_id     = var.cognito_user_pool_id != "" ? var.cognito_user_pool_id : aws_cognito_user_pool.this.id
  cognito_domain_name = var.cognito_existing_domain_prefix != "" ? var.cognito_existing_domain_prefix : aws_cognito_user_pool_domain.this.domain

  service_env_common = {
    for app, cfg in local.apps : app => {
      NODE_ENV                  = "production"
      SENTRY_ENVIRONMENT        = var.environment
      BYPASS_TRIAL_RESTRICTIONS = tostring(var.bypass_trial_restrictions)
      AWS_REGION                = var.aws_region
      BASE_DOMAIN               = var.root_domain
      REDIS_ENABLED             = tostring(var.enable_valkey)
      BACKEND_URL               = "https://${local.fqdn[app].api}"
      FRONTEND_URL              = "https://${local.fqdn[app].frontend}"
    }
  }

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
      SNS_INTER_APP_TOPIC_ARN         = module.messaging.topic_arns["inter_app_events"]
      SNS_BROADCAST_TOPIC_ARN         = module.messaging.topic_arns["inter_app_broadcast"]
      SQS_WRAPPER_QUEUE_URL           = module.messaging.queue_urls["wrapper_events"]
      SQS_NOTIFICATIONS_IMMEDIATE_URL = module.messaging.queue_urls["notifications_immediate"]
      SQS_NOTIFICATIONS_BULK_URL      = module.messaging.queue_urls["notifications_bulk"]
      SQS_NOTIFICATIONS_SCHEDULED_URL = module.messaging.queue_urls["notifications_scheduled"]
      SNS_LARGE_PAYLOAD_BUCKET        = aws_s3_bucket.buckets["claim_check"].id
      S3_LOGO_BUCKET                  = var.logo_bucket_override != "" ? var.logo_bucket_override : aws_s3_bucket.buckets["wrapper_logos"].id
      CRM_APP_URL                     = "https://${local.fqdn["crm"].frontend}"
      ACCOUNTING_APP_URL              = "https://${local.fqdn["fa"].frontend}"
      BLOG_SITE_URL                   = "https://www.${var.root_domain}"
      BLOG_PUBLIC_BASE_URL            = "https://${local.fqdn["wrapper"].api}"
    })
    crm = merge(local.app_env["crm"], {
      PORT                   = "4000"
      SQS_INBOUND_QUEUE_URL  = module.messaging.queue_urls["crm_events"]
      SQS_INBOUND_REGION     = var.aws_region
      AWS_S3_BUCKET_NAME     = aws_s3_bucket.buckets["crm_attachments"].id
      SNS_BUSINESS_TOPIC_ARN = module.messaging.topic_arns["business_events"]
      WRAPPER_API_URL        = "https://${local.fqdn["wrapper"].api}"
      CORS_ORIGINS           = "https://${local.fqdn["crm"].frontend}"
      CLIENT_URL             = "https://${local.fqdn["crm"].frontend}"
    })
    fa = merge(local.app_env["fa"], {
      SERVER_PORT                   = "3002"
      PORT                          = "3002"
      SQS_ACCOUNTING_QUEUE_URL      = module.messaging.queue_urls["accounting_events"]
      SQS_BUSINESS_EVENTS_QUEUE_URL = module.messaging.queue_urls["business_events_fa"]
      SQS_ACCOUNTING_DLQ_URL        = module.messaging.dlq_urls["accounting_events"]
      SNS_BUSINESS_TOPIC_ARN        = module.messaging.topic_arns["business_events"]
      S3_RECEIPTS_BUCKET            = aws_s3_bucket.buckets["fa_receipts"].id
      WRAPPER_API_URL               = "https://${local.fqdn["wrapper"].api}"
      CORS_ORIGINS                  = "https://${local.fqdn["fa"].frontend}"
    })
    lens = merge(local.app_env["lens"], {
      SERVER_PORT                      = "3002"
      PORT                             = "3002"
      CORS_ORIGINS                     = "https://${local.fqdn["lens"].frontend}"
      PUBLIC_APP_ORIGIN                = "https://${local.fqdn["lens"].frontend}"
      APP_PUBLIC_URL                   = "https://${local.fqdn["lens"].frontend}"
      TENANT_RLS_ENABLED               = "true"
      TENANT_HOST_SUFFIX               = local.fqdn["lens"].frontend
      DATABASE_SSL_REJECT_UNAUTHORIZED = "true"
      JWT_EXPIRES_IN                   = "8h"
      RATE_LIMIT_MAX                   = "2000"
      WORKFLOW_CRON_ENABLED            = "true"
      WORKFLOW_CRON_INTERVAL_MS        = "3600000"
      TRANSACTIONAL_EMAIL_PROVIDER     = "brevo"
      BREVO_FROM_EMAIL                 = "platformadmin@zopkit.com"
      BREVO_FROM_NAME                  = "Zopkit Lens"
      NODE_ENV                         = "production"
    })

    academy = merge(local.app_env["academy"], {
      HOST                      = "0.0.0.0"
      PORT                      = "8000"
      JWT_EXPIRES_IN            = "15m"
      REFRESH_TOKEN_EXPIRES_IN  = "7d"
      RATE_LIMIT_MAX            = "1000"
      RATE_LIMIT_WINDOW         = "1 minute"
      CORS_ORIGIN               = "https://${local.fqdn["academy"].frontend}"
      GOOGLE_OAUTH_REDIRECT_URI = "https://${local.fqdn["academy"].api}/api/auth/google/callback"
    })

    entertainment-erp = merge(local.app_env["entertainment-erp"], {
      PORT                 = "8080"
      CORS_ORIGINS         = "https://entertainment.zopkit.com"
      ENABLE_RLS           = "false"
      REGISTRATION_ENABLED = "true"
      STORAGE_DRIVER       = "local"
      FILE_STORAGE_PATH    = "./uploads"
    })
  }

  valkey_secret_keys = var.enable_valkey ? ["REDIS_URL", "REDIS_PASSWORD"] : []

  service_secret_keys = {
    for app, cfg in local.apps : app => [
      for k in distinct(concat(local.app_secret_keys[app], local.valkey_secret_keys)) :
      k if !contains(keys(local.service_env[app]), k)
    ]
  }

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
