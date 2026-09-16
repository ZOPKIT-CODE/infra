# The whole suite stack, instantiated for staging.
#
# Every environment-specific value comes from this directory's terraform.tfvars;
# the stack module itself is identical across environments.
module "stack" {
  source = "../../modules/stack"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
    aws.crm_data  = aws.crm_data
  }

  alarm_email                     = var.alarm_email
  apex_frontend_app               = var.apex_frontend_app
  aws_region                      = var.aws_region
  az_count                        = var.az_count
  bypass_trial_restrictions       = var.bypass_trial_restrictions
  cognito_client_ids              = var.cognito_client_ids
  cognito_domain_prefix           = var.cognito_domain_prefix
  cognito_existing_domain_prefix  = var.cognito_existing_domain_prefix
  cognito_user_pool_id            = var.cognito_user_pool_id
  create_route53_zone             = var.create_route53_zone
  data_region                     = var.data_region
  disabled_frontends              = var.disabled_frontends
  dns_only_live_apps              = var.dns_only_live_apps
  enable_bastion                  = var.enable_bastion
  enable_ci_oidc                  = var.enable_ci_oidc
  enable_mathesar                 = var.enable_mathesar
  enable_rds                      = var.enable_rds
  enable_ses_inbound              = var.enable_ses_inbound
  enable_valkey                   = var.enable_valkey
  environment                     = var.environment
  fargate_assign_public_ip        = var.fargate_assign_public_ip
  github_deploy_repos             = var.github_deploy_repos
  image_tag                       = var.image_tag
  log_retention_days              = var.log_retention_days
  logo_bucket_override            = var.logo_bucket_override
  manage_apex_dns                 = var.manage_apex_dns
  manage_ecr                      = var.manage_ecr
  mathesar_cognito_client_id      = var.mathesar_cognito_client_id
  mathesar_cognito_domain         = var.mathesar_cognito_domain
  mathesar_cognito_user_pool_arn  = var.mathesar_cognito_user_pool_arn
  mutable_tag_repos               = var.mutable_tag_repos
  project                         = var.project
  rds_admin_cidrs                 = var.rds_admin_cidrs
  rds_deletion_protection         = var.rds_deletion_protection
  rds_instance_class              = var.rds_instance_class
  rds_publicly_accessible         = var.rds_publicly_accessible
  rds_skip_final_snapshot         = var.rds_skip_final_snapshot
  root_domain                     = var.root_domain
  service_cpu_overrides           = var.service_cpu_overrides
  service_desired_count_overrides = var.service_desired_count_overrides
  service_enabled_overrides       = var.service_enabled_overrides
  service_image_tags              = var.service_image_tags
  service_memory_overrides        = var.service_memory_overrides
  single_nat_gateway              = var.single_nat_gateway
  valkey_node_type                = var.valkey_node_type
  valkey_replicas                 = var.valkey_replicas
  vpc_cidr                        = var.vpc_cidr
}

# ---------------------------------------------------------------------------
# Address migration: this directory adopts the state that the root module used
# to own, so every address gains a `module.stack.` prefix. Without these blocks
# Terraform reads all 65 resources as new and plans destroy+create.
#
# A single `moved` on a module address carries every resource inside it, which
# is why the 8 module entries cover far more than 8 resources.
#
# Keep these indefinitely — they are cheap, and they are the only record of how
# the pre-staging-directory state maps onto the current layout.
# ---------------------------------------------------------------------------
moved {
  from = module.bastion
  to   = module.stack.module.bastion
}

moved {
  from = module.ci_oidc
  to   = module.stack.module.ci_oidc
}

moved {
  from = module.db_admin
  to   = module.stack.module.db_admin
}

moved {
  from = module.mathesar
  to   = module.stack.module.mathesar
}

moved {
  from = module.messaging
  to   = module.stack.module.messaging
}

moved {
  from = module.observability
  to   = module.stack.module.observability
}

moved {
  from = module.services
  to   = module.stack.module.services
}

moved {
  from = module.vpc
  to   = module.stack.module.vpc
}

moved {
  from = aws_acm_certificate.cloudfront
  to   = module.stack.aws_acm_certificate.cloudfront
}

moved {
  from = aws_acm_certificate.wildcard
  to   = module.stack.aws_acm_certificate.wildcard
}

moved {
  from = aws_acm_certificate_validation.cloudfront
  to   = module.stack.aws_acm_certificate_validation.cloudfront
}

moved {
  from = aws_acm_certificate_validation.wildcard
  to   = module.stack.aws_acm_certificate_validation.wildcard
}

moved {
  from = aws_cloudfront_distribution.frontends
  to   = module.stack.aws_cloudfront_distribution.frontends
}

moved {
  from = aws_cloudfront_distribution.marketing
  to   = module.stack.aws_cloudfront_distribution.marketing
}

moved {
  from = aws_cloudfront_function.spa_routing
  to   = module.stack.aws_cloudfront_function.spa_routing
}

moved {
  from = aws_cloudfront_origin_access_control.this
  to   = module.stack.aws_cloudfront_origin_access_control.this
}

moved {
  from = aws_cognito_user_pool.this
  to   = module.stack.aws_cognito_user_pool.this
}

moved {
  from = aws_cognito_user_pool_client.clients
  to   = module.stack.aws_cognito_user_pool_client.clients
}

moved {
  from = aws_cognito_user_pool_domain.this
  to   = module.stack.aws_cognito_user_pool_domain.this
}

moved {
  from = aws_db_instance.this
  to   = module.stack.aws_db_instance.this
}

moved {
  from = aws_db_subnet_group.this
  to   = module.stack.aws_db_subnet_group.this
}

moved {
  from = aws_ecr_lifecycle_policy.repos
  to   = module.stack.aws_ecr_lifecycle_policy.repos
}

moved {
  from = aws_ecr_repository.repos
  to   = module.stack.aws_ecr_repository.repos
}

moved {
  from = aws_ecs_cluster.this
  to   = module.stack.aws_ecs_cluster.this
}

moved {
  from = aws_ecs_cluster_capacity_providers.this
  to   = module.stack.aws_ecs_cluster_capacity_providers.this
}

moved {
  from = aws_elasticache_replication_group.valkey
  to   = module.stack.aws_elasticache_replication_group.valkey
}

moved {
  from = aws_elasticache_subnet_group.valkey
  to   = module.stack.aws_elasticache_subnet_group.valkey
}

moved {
  from = aws_iam_policy.db_admin
  to   = module.stack.aws_iam_policy.db_admin
}

moved {
  from = aws_iam_policy.db_dev_app
  to   = module.stack.aws_iam_policy.db_dev_app
}

moved {
  from = aws_iam_role.blog_bot_router
  to   = module.stack.aws_iam_role.blog_bot_router
}

moved {
  from = aws_iam_role.execution
  to   = module.stack.aws_iam_role.execution
}

moved {
  from = aws_iam_role.task
  to   = module.stack.aws_iam_role.task
}

moved {
  from = aws_iam_role_policy.crm
  to   = module.stack.aws_iam_role_policy.crm
}

moved {
  from = aws_iam_role_policy.execution_secrets
  to   = module.stack.aws_iam_role_policy.execution_secrets
}

moved {
  from = aws_iam_role_policy.fa
  to   = module.stack.aws_iam_role_policy.fa
}

moved {
  from = aws_iam_role_policy.lens
  to   = module.stack.aws_iam_role_policy.lens
}

moved {
  from = aws_iam_role_policy.wrapper
  to   = module.stack.aws_iam_role_policy.wrapper
}

moved {
  from = aws_iam_role_policy_attachment.blog_bot_router_logs
  to   = module.stack.aws_iam_role_policy_attachment.blog_bot_router_logs
}

moved {
  from = aws_iam_role_policy_attachment.execution_managed
  to   = module.stack.aws_iam_role_policy_attachment.execution_managed
}

moved {
  from = aws_lambda_function.blog_bot_router
  to   = module.stack.aws_lambda_function.blog_bot_router
}

moved {
  from = aws_lb.this
  to   = module.stack.aws_lb.this
}

moved {
  from = aws_lb_listener.http
  to   = module.stack.aws_lb_listener.http
}

moved {
  from = aws_lb_listener.https
  to   = module.stack.aws_lb_listener.https
}

moved {
  from = aws_lb_listener_rule.tenant_wildcard
  to   = module.stack.aws_lb_listener_rule.tenant_wildcard
}

moved {
  from = aws_route53_record.acm_validation
  to   = module.stack.aws_route53_record.acm_validation
}

moved {
  from = aws_route53_record.apex_frontend
  to   = module.stack.aws_route53_record.apex_frontend
}

moved {
  from = aws_route53_record.api
  to   = module.stack.aws_route53_record.api
}

moved {
  from = aws_route53_record.frontend
  to   = module.stack.aws_route53_record.frontend
}

moved {
  from = aws_route53_record.tenant_wildcard
  to   = module.stack.aws_route53_record.tenant_wildcard
}

moved {
  from = aws_route53_record.zone_delegation
  to   = module.stack.aws_route53_record.zone_delegation
}

moved {
  from = aws_route53_zone.this
  to   = module.stack.aws_route53_zone.this
}

moved {
  from = aws_s3_bucket.buckets
  to   = module.stack.aws_s3_bucket.buckets
}

moved {
  from = aws_s3_bucket_cors_configuration.crm_attachments
  to   = module.stack.aws_s3_bucket_cors_configuration.crm_attachments
}

moved {
  from = aws_s3_bucket_cors_configuration.fa_receipts
  to   = module.stack.aws_s3_bucket_cors_configuration.fa_receipts
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.ephemeral
  to   = module.stack.aws_s3_bucket_lifecycle_configuration.ephemeral
}

moved {
  from = aws_s3_bucket_policy.frontend
  to   = module.stack.aws_s3_bucket_policy.frontend
}

moved {
  from = aws_s3_bucket_public_access_block.buckets
  to   = module.stack.aws_s3_bucket_public_access_block.buckets
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.buckets
  to   = module.stack.aws_s3_bucket_server_side_encryption_configuration.buckets
}

moved {
  from = aws_s3_bucket_versioning.buckets
  to   = module.stack.aws_s3_bucket_versioning.buckets
}

moved {
  from = aws_secretsmanager_secret.app
  to   = module.stack.aws_secretsmanager_secret.app
}

moved {
  from = aws_secretsmanager_secret.rds_master
  to   = module.stack.aws_secretsmanager_secret.rds_master
}

moved {
  from = aws_secretsmanager_secret.valkey
  to   = module.stack.aws_secretsmanager_secret.valkey
}

moved {
  from = aws_secretsmanager_secret_version.app
  to   = module.stack.aws_secretsmanager_secret_version.app
}

moved {
  from = aws_secretsmanager_secret_version.rds_master
  to   = module.stack.aws_secretsmanager_secret_version.rds_master
}

moved {
  from = aws_secretsmanager_secret_version.valkey
  to   = module.stack.aws_secretsmanager_secret_version.valkey
}

moved {
  from = aws_security_group.alb
  to   = module.stack.aws_security_group.alb
}

moved {
  from = aws_security_group.rds
  to   = module.stack.aws_security_group.rds
}

moved {
  from = aws_security_group.tasks
  to   = module.stack.aws_security_group.tasks
}

moved {
  from = aws_security_group.valkey
  to   = module.stack.aws_security_group.valkey
}

moved {
  from = aws_security_group_rule.tasks_egress_all
  to   = module.stack.aws_security_group_rule.tasks_egress_all
}

moved {
  from = aws_security_group_rule.tasks_from_alb
  to   = module.stack.aws_security_group_rule.tasks_from_alb
}

moved {
  from = random_password.rds_master
  to   = module.stack.random_password.rds_master
}

moved {
  from = random_password.valkey
  to   = module.stack.random_password.valkey
}

# ---------------------------------------------------------------------------
# Second-generation moves: the six modules extracted from the flat root
# (observability, messaging, ci-oidc, bastion, db-admin, mathesar).
#
# These MUST live here, not inside modules/stack. A `moved` block resolves its
# addresses relative to the module that declares it, so the same block inside
# the stack would read `from` as module.stack.<addr> — an address state has
# never held — and every one of these resources would be planned for destroy.
# ---------------------------------------------------------------------------
moved {
  from = aws_iam_role.bastion
  to   = module.stack.module.bastion.aws_iam_role.bastion
}

moved {
  from = aws_iam_role_policy_attachment.bastion_ssm
  to   = module.stack.module.bastion.aws_iam_role_policy_attachment.bastion_ssm
}

moved {
  from = aws_iam_instance_profile.bastion
  to   = module.stack.module.bastion.aws_iam_instance_profile.bastion
}

moved {
  from = aws_security_group.bastion
  to   = module.stack.module.bastion.aws_security_group.bastion
}

moved {
  from = aws_instance.bastion
  to   = module.stack.module.bastion.aws_instance.bastion
}

moved {
  from = aws_iam_openid_connect_provider.github
  to   = module.stack.module.ci_oidc.aws_iam_openid_connect_provider.github
}

moved {
  from = aws_iam_role.github_deploy
  to   = module.stack.module.ci_oidc.aws_iam_role.github_deploy
}

moved {
  from = aws_iam_role_policy.github_deploy
  to   = module.stack.module.ci_oidc.aws_iam_role_policy.github_deploy
}

moved {
  from = aws_iam_role.infra_apply
  to   = module.stack.module.ci_oidc.aws_iam_role.infra_apply
}

moved {
  from = aws_iam_role_policy.infra_apply
  to   = module.stack.module.ci_oidc.aws_iam_role_policy.infra_apply
}

moved {
  from = aws_cloudwatch_log_group.db_admin
  to   = module.stack.module.db_admin.aws_cloudwatch_log_group.db_admin
}

moved {
  from = aws_ecs_task_definition.db_admin
  to   = module.stack.module.db_admin.aws_ecs_task_definition.db_admin
}

moved {
  from = random_password.mathesar_db
  to   = module.stack.module.mathesar.random_password.mathesar_db
}

moved {
  from = random_password.mathesar_secret_key
  to   = module.stack.module.mathesar.random_password.mathesar_secret_key
}

moved {
  from = aws_secretsmanager_secret.mathesar
  to   = module.stack.module.mathesar.aws_secretsmanager_secret.mathesar
}

moved {
  from = aws_secretsmanager_secret_version.mathesar
  to   = module.stack.module.mathesar.aws_secretsmanager_secret_version.mathesar
}

moved {
  from = aws_security_group_rule.tasks_from_alb_mathesar
  to   = module.stack.module.mathesar.aws_security_group_rule.tasks_from_alb_mathesar
}

moved {
  from = aws_cloudwatch_log_group.mathesar
  to   = module.stack.module.mathesar.aws_cloudwatch_log_group.mathesar
}

moved {
  from = aws_ecs_task_definition.mathesar
  to   = module.stack.module.mathesar.aws_ecs_task_definition.mathesar
}

moved {
  from = aws_lb_target_group.mathesar
  to   = module.stack.module.mathesar.aws_lb_target_group.mathesar
}

moved {
  from = aws_lb_listener_rule.mathesar
  to   = module.stack.module.mathesar.aws_lb_listener_rule.mathesar
}

moved {
  from = aws_ecs_service.mathesar
  to   = module.stack.module.mathesar.aws_ecs_service.mathesar
}

moved {
  from = aws_route53_record.mathesar
  to   = module.stack.module.mathesar.aws_route53_record.mathesar
}

moved {
  from = aws_sns_topic.topics
  to   = module.stack.module.messaging.aws_sns_topic.topics
}

moved {
  from = aws_sqs_queue.main
  to   = module.stack.module.messaging.aws_sqs_queue.main
}

moved {
  from = aws_sqs_queue.dlq
  to   = module.stack.module.messaging.aws_sqs_queue.dlq
}

moved {
  from = aws_sqs_queue_policy.main
  to   = module.stack.module.messaging.aws_sqs_queue_policy.main
}

moved {
  from = aws_sns_topic_subscription.targeted
  to   = module.stack.module.messaging.aws_sns_topic_subscription.targeted
}

moved {
  from = aws_sns_topic_subscription.broadcast
  to   = module.stack.module.messaging.aws_sns_topic_subscription.broadcast
}

moved {
  from = aws_sns_topic_subscription.business
  to   = module.stack.module.messaging.aws_sns_topic_subscription.business
}

moved {
  from = aws_cloudwatch_metric_alarm.dlq_not_empty
  to   = module.stack.module.messaging.aws_cloudwatch_metric_alarm.dlq_not_empty
}

moved {
  from = aws_cloudwatch_metric_alarm.accounting_backlog_expiry
  to   = module.stack.module.messaging.aws_cloudwatch_metric_alarm.accounting_backlog_expiry
}

moved {
  from = aws_cloudwatch_log_group.service
  to   = module.stack.module.observability.aws_cloudwatch_log_group.service
}

moved {
  from = aws_sns_topic.ops_alarms
  to   = module.stack.module.observability.aws_sns_topic.ops_alarms
}

moved {
  from = aws_sns_topic_subscription.ops_alarms_email
  to   = module.stack.module.observability.aws_sns_topic_subscription.ops_alarms_email
}
