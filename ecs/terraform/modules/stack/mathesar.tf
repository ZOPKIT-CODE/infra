module "mathesar" {
  source = "../mathesar"

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

#
# The two random_password resources are the dangerous ones — without a moved
# block Terraform would generate NEW values, silently rotating Mathesar's DB
# password and Django secret key away from what the running service holds.
# Re-exported so the root output surface is unchanged by the move.
output "mathesar_url" {
  description = "Mathesar UI URL. Null when the service is disabled."
  value       = module.mathesar.mathesar_url
}
