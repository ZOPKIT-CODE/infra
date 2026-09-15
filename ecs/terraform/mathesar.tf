module "mathesar" {
  source = "./modules/mathesar"

  name_prefix = local.name_prefix
  enabled     = var.enable_mathesar && var.enable_rds
  environment = var.environment
  aws_region  = var.aws_region

  root_domain     = var.root_domain
  route53_zone_id = local.route53_zone_id

  vpc_id                   = module.vpc.vpc_id
  private_subnet_ids       = module.vpc.private_subnets
  public_subnet_ids        = module.vpc.public_subnets
  fargate_assign_public_ip = var.fargate_assign_public_ip

  cluster_id              = aws_ecs_cluster.this.id
  execution_role_arn      = aws_iam_role.execution.arn
  alb_listener_arn        = aws_lb_listener.https.arn
  alb_dns_name            = aws_lb.this.dns_name
  alb_zone_id             = aws_lb.this.zone_id
  alb_security_group_id   = aws_security_group.alb.id
  tasks_security_group_id = aws_security_group.tasks.id
  db_address              = one(aws_db_instance.this[*].address)

  mathesar_cognito_user_pool_arn = var.mathesar_cognito_user_pool_arn
  mathesar_cognito_client_id     = var.mathesar_cognito_client_id
  mathesar_cognito_domain        = var.mathesar_cognito_domain

  tags = local.common_tags
}

# Address migration: moved from this file into ./modules/mathesar.
#
# The two random_password resources are the dangerous ones — without a moved
# block Terraform would generate NEW values, silently rotating Mathesar's DB
# password and Django secret key away from what the running service holds.
moved {
  from = random_password.mathesar_db
  to   = module.mathesar.random_password.mathesar_db
}

moved {
  from = random_password.mathesar_secret_key
  to   = module.mathesar.random_password.mathesar_secret_key
}

moved {
  from = aws_secretsmanager_secret.mathesar
  to   = module.mathesar.aws_secretsmanager_secret.mathesar
}

moved {
  from = aws_secretsmanager_secret_version.mathesar
  to   = module.mathesar.aws_secretsmanager_secret_version.mathesar
}

moved {
  from = aws_security_group_rule.tasks_from_alb_mathesar
  to   = module.mathesar.aws_security_group_rule.tasks_from_alb_mathesar
}

moved {
  from = aws_cloudwatch_log_group.mathesar
  to   = module.mathesar.aws_cloudwatch_log_group.mathesar
}

moved {
  from = aws_ecs_task_definition.mathesar
  to   = module.mathesar.aws_ecs_task_definition.mathesar
}

moved {
  from = aws_lb_target_group.mathesar
  to   = module.mathesar.aws_lb_target_group.mathesar
}

moved {
  from = aws_lb_listener_rule.mathesar
  to   = module.mathesar.aws_lb_listener_rule.mathesar
}

moved {
  from = aws_ecs_service.mathesar
  to   = module.mathesar.aws_ecs_service.mathesar
}

moved {
  from = aws_route53_record.mathesar
  to   = module.mathesar.aws_route53_record.mathesar
}

# Re-exported so the root output surface is unchanged by the move.
output "mathesar_url" {
  description = "Mathesar UI URL. Null when the service is disabled."
  value       = module.mathesar.mathesar_url
}
