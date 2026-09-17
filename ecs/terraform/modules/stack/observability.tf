module "observability" {
  source = "../observability"

  name_prefix        = local.name_prefix
  services           = local.services
  log_retention_days = var.log_retention_days
  alarm_email        = var.alarm_email
}
