module "db_admin" {
  source = "./modules/db-admin"

  name_prefix           = local.name_prefix
  enabled               = var.enable_rds
  aws_region            = var.aws_region
  execution_role_arn    = aws_iam_role.execution.arn
  rds_master_secret_arn = one(aws_secretsmanager_secret.rds_master[*].arn)
  tags                  = local.common_tags
}

# Address migration: moved from this file into ./modules/db-admin.
moved {
  from = aws_cloudwatch_log_group.db_admin
  to   = module.db_admin.aws_cloudwatch_log_group.db_admin
}

moved {
  from = aws_ecs_task_definition.db_admin
  to   = module.db_admin.aws_ecs_task_definition.db_admin
}
