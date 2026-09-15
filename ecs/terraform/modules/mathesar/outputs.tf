output "mathesar_url" {
  description = "Mathesar UI URL (in-VPC, behind the ALB)."
  value       = var.enabled ? "https://db.${var.root_domain}" : null
}

output "secret_arn" {
  description = "Secrets Manager ARN holding Mathesar's DB password and Django secret key. Null when disabled."
  value       = one(aws_secretsmanager_secret.mathesar[*].arn)
}
