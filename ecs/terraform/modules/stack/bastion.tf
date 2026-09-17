module "bastion" {
  source = "../bastion"

  name_prefix       = local.name_prefix
  enabled           = var.enable_rds && var.enable_bastion
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnets
  tags              = local.common_tags
}

output "bastion_instance_id" {
  description = "SSM bastion instance ID. Null when enable_bastion = false."
  value       = module.bastion.bastion_instance_id
}
