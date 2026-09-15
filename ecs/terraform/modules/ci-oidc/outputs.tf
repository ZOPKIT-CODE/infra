output "github_deploy_role_arn" {
  description = "ARN to put in each repo's GitHub Actions workflow (role-to-assume). Null in envs with enable_ci_oidc=false."
  value       = one(aws_iam_role.github_deploy[*].arn)
}

output "infra_apply_role_arn" {
  description = "Role assumed by the infra-apply workflow (full terraform apply). Gated to the infra-* GitHub environments."
  value       = one(aws_iam_role.infra_apply[*].arn)
}

output "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN. Null in envs with enable_ci_oidc=false."
  value       = one(aws_iam_openid_connect_provider.github[*].arn)
}
