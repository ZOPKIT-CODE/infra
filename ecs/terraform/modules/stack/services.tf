data "aws_ssm_parameter" "deployed_tag" {
  for_each = { for k, v in local.services : k => v if v.enabled && !contains(keys(var.service_image_tags), k) }
  name     = "/${var.project}/${var.environment}/deployed-tag/${each.key}"
}

module "services" {
  source   = "../ecs-service"
  for_each = { for k, v in local.services : k => v if v.enabled }

  name         = each.key
  name_prefix  = local.name_prefix
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name
  aws_region   = var.aws_region

  image  = "${local.ecr_repo_urls[each.value.ecr_repo]}:${try(var.service_image_tags[each.key], data.aws_ssm_parameter.deployed_tag[each.key].value)}"
  cpu    = each.value.cpu
  memory = each.value.memory

  container_port = each.value.container_port
  command        = each.value.command

  environment = merge(local.service_env[each.value.app], each.value.extra_env)
  secrets     = local.service_secrets[each.value.app]

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task[each.value.role].arn

  log_group_name = module.observability.log_group_names[each.key]

  desired_count           = each.value.desired_count
  subnet_ids              = var.fargate_assign_public_ip ? module.vpc.public_subnets : module.vpc.private_subnets
  task_security_group_ids = [aws_security_group.tasks.id]
  assign_public_ip        = var.fargate_assign_public_ip

  needs_alb                         = each.value.needs_alb
  vpc_id                            = each.value.needs_alb ? module.vpc.vpc_id : null
  alb_listener_arn                  = each.value.needs_alb ? aws_lb_listener.https.arn : null
  listener_rule_priority            = each.value.listener_rule_priority
  host_header                       = each.value.host_header
  extra_host_headers                = try(each.value.extra_host_headers, [])
  health_check_path                 = each.value.health_check_path
  stickiness_enabled                = each.value.stickiness_enabled
  target_group_name                 = try(each.value.target_group_name, null)
  health_check_grace_period_seconds = each.value.health_check_grace_period_seconds

  autoscaling_enabled = each.value.autoscaling_enabled
  min_count           = each.value.min_count
  max_count           = each.value.max_count

  tags = local.common_tags
}
