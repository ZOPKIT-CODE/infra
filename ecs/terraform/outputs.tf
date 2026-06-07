# ---------------------------------------------------------------------------
# Outputs for the ECS Fargate stack. EKS/namespace/IRSA/Helm app_wiring outputs
# are dropped; these surface the ECS cluster, shared ALB, registry, messaging,
# cache, Cognito, storage/CDN, secrets, and the per-service ECS handles.
# ---------------------------------------------------------------------------

output "region" {
  value = var.aws_region
}

# --- ECS compute ---
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

# --- Load balancer ---
output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

# --- Container registry ---
output "ecr_repository_urls" {
  description = "ECR repo URLs keyed by repo name."
  value       = local.ecr_repo_urls
}

# --- Messaging ---
output "sns_topic_arns" {
  value = { for k, t in aws_sns_topic.topics : k => t.arn }
}

output "sqs_queue_urls" {
  value = { for k, q in aws_sqs_queue.main : k => q.url }
}

output "sqs_dlq_urls" {
  value = { for k, q in aws_sqs_queue.dlq : k => q.url }
}

# --- Cache ---
output "valkey_primary_endpoint" {
  value = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "valkey_secret_arn" {
  description = "Secrets Manager ARN holding the Valkey AUTH token + rediss:// URL."
  value       = aws_secretsmanager_secret.valkey.arn
}

# --- TLS ---
output "acm_cert_arn" {
  description = "Primary-region wildcard ACM cert ARN for the shared ALB."
  value       = local.acm_cert_arn
}

# --- Cognito ---
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

# --- Storage / CDN ---
output "s3_bucket_names" {
  value = { for k, b in aws_s3_bucket.buckets : k => b.id }
}

output "cloudfront_domains" {
  description = "CloudFront distribution domains keyed by app (point the frontend DNS here)."
  value       = { for k, d in aws_cloudfront_distribution.frontends : k => d.domain_name }
}

# --- Secrets (containers; values filled out-of-band) ---
output "app_secret_arns" {
  value = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
}
