module "bastion" {
  source = "./modules/bastion"

  name_prefix       = local.name_prefix
  enabled           = var.enable_rds && var.enable_bastion
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnets
  tags              = local.common_tags
}

# Address migration: moved from this file into ./modules/bastion. The bastion is
# currently disabled (enable_bastion = false), so these instances are already
# planned for destroy — the blocks keep that a clean destroy of the MOVED
# addresses rather than a destroy of the old plus a no-op create of the new.
moved {
  from = aws_iam_role.bastion
  to   = module.bastion.aws_iam_role.bastion
}

moved {
  from = aws_iam_role_policy_attachment.bastion_ssm
  to   = module.bastion.aws_iam_role_policy_attachment.bastion_ssm
}

moved {
  from = aws_iam_instance_profile.bastion
  to   = module.bastion.aws_iam_instance_profile.bastion
}

moved {
  from = aws_security_group.bastion
  to   = module.bastion.aws_security_group.bastion
}

moved {
  from = aws_instance.bastion
  to   = module.bastion.aws_instance.bastion
}

# Re-exported so the root output surface is unchanged by the move.
output "bastion_instance_id" {
  description = "SSM bastion instance ID. Null when enable_bastion = false."
  value       = module.bastion.bastion_instance_id
}
