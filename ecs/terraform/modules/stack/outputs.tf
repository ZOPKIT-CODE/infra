output "region" {
  value = var.aws_region
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "service_names" {
  description = "ECS service names keyed by service contract key (wrapper-web/crm-web/fa-web/fa-consumer)."
  value       = { for k, m in module.services : k => m.service_name }
}

output "target_group_arns" {
  description = "ALB target group ARNs keyed by service (null for headless workers)."
  value       = { for k, m in module.services : k => m.target_group_arn }
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "ecr_repository_urls" {
  description = "ECR repo URLs keyed by repo name."
  value       = local.ecr_repo_urls
}

output "sns_topic_arns" {
  value = module.messaging.topic_arns
}

output "sqs_queue_urls" {
  value = module.messaging.queue_urls
}

output "sqs_dlq_urls" {
  value = module.messaging.dlq_urls
}

output "valkey_primary_endpoint" {
  value = var.enable_valkey ? aws_elasticache_replication_group.valkey[0].primary_endpoint_address : null
}

output "valkey_secret_arn" {
  description = "Secrets Manager ARN holding the Valkey AUTH token + rediss:// URL."
  value       = var.enable_valkey ? aws_secretsmanager_secret.valkey[0].arn : null
}

output "acm_cert_arn" {
  description = "Primary-region wildcard ACM cert ARN for the shared ALB."
  value       = local.acm_cert_arn
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_user_pool_client_ids" {
  value = { for k, c in aws_cognito_user_pool_client.clients : k => c.id }
}

output "cognito_domain" {
  value = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "cognito_issuer_url" {
  value = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
}

output "s3_bucket_names" {
  value = { for k, b in aws_s3_bucket.buckets : k => b.id }
}

output "cloudfront_domains" {
  description = "CloudFront distribution domains keyed by app (point the frontend DNS here)."
  value       = { for k, d in aws_cloudfront_distribution.frontends : k => d.domain_name }
}

output "app_secret_arns" {
  value = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
}
