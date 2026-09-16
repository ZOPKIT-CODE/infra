module "bastion" {
  source = "../bastion"

  name_prefix       = local.name_prefix
  enabled           = var.enable_rds && var.enable_bastion
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnets
  tags              = local.common_tags
}

# currently disabled (enable_bastion = false), so these instances are already
# planned for destroy — the blocks keep that a clean destroy of the MOVED
# addresses rather than a destroy of the old plus a no-op create of the new.
# Re-exported so the root output surface is unchanged by the move.
output "bastion_instance_id" {
  description = "SSM bastion instance ID. Null when enable_bastion = false."
  value       = module.bastion.bastion_instance_id
}
