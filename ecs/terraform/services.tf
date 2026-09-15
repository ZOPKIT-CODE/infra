# Instantiates modules/ecs-service once per enabled entry in local.services.
#
# DEDUP GUARANTEE: environment and secrets are read from the SAME svc.app, so
# local.service_secrets already excludes any key present in local.service_env —
# ECS rejects a key appearing in both blocks.

# The deployed tag for each service lives in SSM Parameter Store
# (/<project>/<env>/deployed-tag/<service>), written by every release path
# BEFORE its apply (CI deploy.yml, deploy-service.sh). Terraform reads the
# LIVE value at plan time, so unrelated applies can never roll a service back
# to a stale tag. Git holds no tag record anymore: the old
# image-tags.auto.tfvars.json went stale silently (dispatched releases could
# not push to the protected main) and a secrets roll downgraded staging CRM
# four commits (2026-06-12). Bootstrap of a brand-new service: create the
# parameter first (the deploy paths do) or pass -var='service_image_tags={...}'.
data "aws_ssm_parameter" "deployed_tag" {
  for_each = { for k, v in local.services : k => v if v.enabled && !contains(keys(var.service_image_tags), k) }
  name     = "/${var.project}/${var.environment}/deployed-tag/${each.key}"
}

module "services" {
  source = "./modules/ecs-service"
  # Only stand up services flagged enabled (gradual rollout: wrapper now, CRM/FA
  # later by flipping `enabled = true` in local.services). The shared foundation
  # (VPC, cluster, ALB, ECR, SNS/SQS incl. the CRM/FA queues that BUFFER wrapper's
  # events, secrets, Cognito) is created regardless.
  for_each = { for k, v in local.services : k => v if v.enabled }

  name         = each.key
  name_prefix  = local.name_prefix
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name
  aws_region   = var.aws_region

  # --- Task definition ---
  # Tag resolution: explicit -var override wins (emergency pin / bootstrap),
  # otherwise the LIVE deployed tag from SSM (see data source above) — so a
  # secrets roll or full apply from ANY checkout preserves what is running.
  image  = "${local.ecr_repo_urls[each.value.ecr_repo]}:${try(var.service_image_tags[each.key], data.aws_ssm_parameter.deployed_tag[each.key].value)}"
  cpu    = each.value.cpu
  memory = each.value.memory

  container_port = each.value.container_port
  command        = each.value.command

  # Per-app env, plus per-service overrides (e.g. PROCESS_ROLE web/worker for crm).
  environment = merge(local.service_env[each.value.app], each.value.extra_env)
  secrets     = local.service_secrets[each.value.app]

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task[each.value.role].arn

  log_group_name = module.observability.log_group_names[each.key]

  # --- ECS service / networking ---
  desired_count           = each.value.desired_count
  subnet_ids              = var.fargate_assign_public_ip ? module.vpc.public_subnets : module.vpc.private_subnets
  task_security_group_ids = [aws_security_group.tasks.id]
  assign_public_ip        = var.fargate_assign_public_ip

  # --- ALB wiring (web services only; null/false for fa-consumer) ---
  needs_alb              = each.value.needs_alb
  vpc_id                 = each.value.needs_alb ? module.vpc.vpc_id : null
  alb_listener_arn       = each.value.needs_alb ? aws_lb_listener.https.arn : null
  listener_rule_priority = each.value.listener_rule_priority
  host_header            = each.value.host_header
  # Additional hostnames on the same listener rule, for services that front both an
  # API and a SPA (entertainment-erp). Absent = just host_header.
  extra_host_headers = try(each.value.extra_host_headers, [])
  health_check_path  = each.value.health_check_path
  stickiness_enabled = each.value.stickiness_enabled
  # Adopt a pre-existing group name where one differs from the generated
  # "<prefix>-<service>" (academy-web's is ...-academy-tg). Absent = generated.
  target_group_name                 = try(each.value.target_group_name, null)
  health_check_grace_period_seconds = each.value.health_check_grace_period_seconds

  # --- Autoscaling (wrapper-web only; others pinned) ---
  autoscaling_enabled = each.value.autoscaling_enabled
  min_count           = each.value.min_count
  max_count           = each.value.max_count

  tags = local.common_tags
}
