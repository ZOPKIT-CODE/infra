###############################################################################
# modules/ecs-service — outputs
###############################################################################

output "service_name" {
  description = "ECS service name (<name_prefix>-<name>)."
  value       = aws_ecs_service.this.name
}

output "service_arn" {
  description = "ECS service ARN/id."
  value       = aws_ecs_service.this.id
}

output "task_definition_arn" {
  description = "Active task definition ARN."
  value       = aws_ecs_task_definition.this.arn
}

output "target_group_arn" {
  description = "Target group ARN for ALB-fronted services; null for workers."
  value       = var.needs_alb ? aws_lb_target_group.this[0].arn : null
}
