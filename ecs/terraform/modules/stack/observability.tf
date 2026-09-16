module "observability" {
  source = "../observability"

  name_prefix        = local.name_prefix
  services           = local.services
  log_retention_days = var.log_retention_days
  alarm_email        = var.alarm_email
}

# ./modules/observability. Without these blocks Terraform reads the new
# addresses as new resources and plans destroy+create. Keep them indefinitely —
# they are also what makes the move land correctly in the `prod` workspace.
