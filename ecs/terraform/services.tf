# ---------------------------------------------------------------------------
# services.tf — Instantiates modules/ecs-service once per entry in
# local.services (the 4-service ECS contract: wrapper-web, crm-web, fa-web,
# fa-consumer). Each invocation wires:
#   - image    = "<ecr repo url>:<image_tag>"  (repo keyed by svc.ecr_repo)
#   - environment = local.service_env[svc.app]     (plain env)
#   - secrets     = local.service_secrets[svc.app]  (deduped valueFrom map)
#   - task_role_arn      = aws_iam_role.task[svc.role].arn  (fa-web + fa-consumer share "fa")
#   - execution_role_arn = aws_iam_role.execution.arn       (shared)
#   - log_group_name     = aws_cloudwatch_log_group.service[<name>].name
#   - subnets / SG / assign_public_ip per var.fargate_assign_public_ip
#   - ALB wiring (listener arn + TG host/health/stickiness/priority) for the
#     three web services; fa-consumer is headless (needs_alb = false) with a
#     command override.
#
# DEDUP GUARANTEE: environment and secrets are taken from the SAME svc.app, so
# local.service_secrets already excludes any key present in local.service_env
# (ECS rejects a key appearing in both blocks).
# ---------------------------------------------------------------------------

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
  # Per-service tag override (service_image_tags["wrapper-web"] = "<sha>") falls
  # back to the global var.image_tag — lets you roll out one app at a time.
  image  = "${local.ecr_repo_urls[each.value.ecr_repo]}:${lookup(var.service_image_tags, each.key, var.image_tag)}"
  cpu    = each.value.cpu
  memory = each.value.memory

  container_port = each.value.container_port
  command        = each.value.command

  # Per-app env, plus per-service overrides (e.g. PROCESS_ROLE web/worker for crm).
  environment = merge(local.service_env[each.value.app], each.value.extra_env)
  secrets     = local.service_secrets[each.value.app]

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task[each.value.role].arn

  log_group_name = aws_cloudwatch_log_group.service[each.key].name

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
  health_check_path      = each.value.health_check_path
  stickiness_enabled     = each.value.stickiness_enabled

  # --- Autoscaling (wrapper-web only; others pinned) ---
  autoscaling_enabled = each.value.autoscaling_enabled
  min_count           = each.value.min_count
  max_count           = each.value.max_count

  tags = local.common_tags
}
