output "acm_cert_arn" {
  value = module.stack.acm_cert_arn
}

output "alb_dns_name" {
  value = module.stack.alb_dns_name
}

output "alb_zone_id" {
  value = module.stack.alb_zone_id
}

output "app_secret_arns" {
  value = module.stack.app_secret_arns
}

output "bastion_instance_id" {
  value = module.stack.bastion_instance_id
}

output "cloudfront_domains" {
  value = module.stack.cloudfront_domains
}

output "cluster_arn" {
  value = module.stack.cluster_arn
}

output "cluster_name" {
  value = module.stack.cluster_name
}

output "cognito_domain" {
  value = module.stack.cognito_domain
}

output "cognito_issuer_url" {
  value = module.stack.cognito_issuer_url
}

output "cognito_user_pool_client_ids" {
  value = module.stack.cognito_user_pool_client_ids
}

output "cognito_user_pool_id" {
  value = module.stack.cognito_user_pool_id
}

output "db_admin_policy_arn" {
  value = module.stack.db_admin_policy_arn
}

output "db_dev_policy_arns" {
  value = module.stack.db_dev_policy_arns
}

output "ecr_repository_urls" {
  value = module.stack.ecr_repository_urls
}

output "github_deploy_role_arn" {
  value = module.stack.github_deploy_role_arn
}

output "infra_apply_role_arn" {
  value = module.stack.infra_apply_role_arn
}

output "mathesar_url" {
  value = module.stack.mathesar_url
}

output "rds_endpoint" {
  value = module.stack.rds_endpoint
}

output "region" {
  value = module.stack.region
}

output "s3_bucket_names" {
  value = module.stack.s3_bucket_names
}

output "service_names" {
  value = module.stack.service_names
}

output "sns_topic_arns" {
  value = module.stack.sns_topic_arns
}

output "sqs_dlq_urls" {
  value = module.stack.sqs_dlq_urls
}

output "sqs_queue_urls" {
  value = module.stack.sqs_queue_urls
}

output "target_group_arns" {
  value = module.stack.target_group_arns
}

output "valkey_primary_endpoint" {
  value = module.stack.valkey_primary_endpoint
}

output "valkey_secret_arn" {
  value = module.stack.valkey_secret_arn
}
