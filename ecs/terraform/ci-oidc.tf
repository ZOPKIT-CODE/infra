module "ci_oidc" {
  source = "./modules/ci-oidc"

  name_prefix         = local.name_prefix
  project             = var.project
  account_id          = local.account_id
  aws_region          = var.aws_region
  enable_ci_oidc      = var.enable_ci_oidc
  github_deploy_repos = var.github_deploy_repos
  tags                = local.common_tags
}

# Address migration: moved from this file into ./modules/ci-oidc. These are
# account-level singletons (the OIDC provider especially) — a destroy+create
# would break every repo's deploy workflow until the new provider exists. Keep
# these blocks indefinitely; they also carry the move into the `prod` workspace.
moved {
  from = aws_iam_openid_connect_provider.github
  to   = module.ci_oidc.aws_iam_openid_connect_provider.github
}

moved {
  from = aws_iam_role.github_deploy
  to   = module.ci_oidc.aws_iam_role.github_deploy
}

moved {
  from = aws_iam_role_policy.github_deploy
  to   = module.ci_oidc.aws_iam_role_policy.github_deploy
}

moved {
  from = aws_iam_role.infra_apply
  to   = module.ci_oidc.aws_iam_role.infra_apply
}

moved {
  from = aws_iam_role_policy.infra_apply
  to   = module.ci_oidc.aws_iam_role_policy.infra_apply
}

# Re-exported so the root output surface is unchanged by the move into the module.
output "github_deploy_role_arn" {
  description = "ARN to put in each repo's GitHub Actions workflow (role-to-assume). Null in envs with enable_ci_oidc=false."
  value       = module.ci_oidc.github_deploy_role_arn
}

output "infra_apply_role_arn" {
  description = "Role assumed by the infra-apply workflow (full terraform apply). Gated to the infra-* GitHub environments."
  value       = module.ci_oidc.infra_apply_role_arn
}
