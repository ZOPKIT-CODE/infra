module "ci_oidc" {
  source = "../ci-oidc"

  name_prefix         = local.name_prefix
  project             = var.project
  account_id          = local.account_id
  aws_region          = var.aws_region
  enable_ci_oidc      = var.enable_ci_oidc
  github_deploy_repos = var.github_deploy_repos
  tags                = local.common_tags
}

output "github_deploy_role_arn" {
  description = "ARN to put in each repo's GitHub Actions workflow (role-to-assume). Null in envs with enable_ci_oidc=false."
  value       = module.ci_oidc.github_deploy_role_arn
}

output "infra_apply_role_arn" {
  description = "Role assumed by the infra-apply workflow (full terraform apply). Gated to the infra-* GitHub environments."
  value       = module.ci_oidc.infra_apply_role_arn
}
