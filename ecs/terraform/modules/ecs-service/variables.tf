###############################################################################
# modules/ecs-service — variable interface
#
# A single reusable module for BOTH ALB-fronted web services and headless
# workers. Variable names are the authoritative module contract — callers in
# ecs.tf pass these verbatim.
###############################################################################

variable "name" {
  description = "Service name suffix, e.g. wrapper-web. Final names use <name_prefix>-<name>."
  type        = string
}

variable "name_prefix" {
  description = "Stack name prefix, e.g. zopkit-staging."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of the shared ECS cluster."
  type        = string
}

variable "cluster_name" {
  description = "Name of the shared ECS cluster (for appautoscaling resource_id)."
  type        = string
}

# --- Task definition ---
variable "image" {
  description = "Full container image URI including tag (e.g. <ecr_url>:<image_tag>)."
  type        = string
}

variable "cpu" {
  description = "Fargate task CPU units (256, 512, 1024, ...)."
  type        = number
}

variable "memory" {
  description = "Fargate task memory in MiB."
  type        = number
}

variable "container_port" {
  description = "Container listen port. Null/0 for headless workers (no port mapping, no ALB)."
  type        = number
  default     = null
}

variable "command" {
  description = "Optional container command override (e.g. the consumer runner). Empty = image default CMD."
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "Plain (non-secret) env vars injected into the task def 'environment' block. Map of KEY => value."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secret env vars injected via 'secrets' valueFrom. Map of KEY => secret-arn-valueFrom string, e.g. KEY = \"<secret-arn>:KEY::\"."
  type        = map(string)
  default     = {}
}

variable "execution_role_arn" {
  description = "Shared ECS task EXECUTION role ARN (ECR pull + logs + GetSecretValue for injection)."
  type        = string
}

variable "task_role_arn" {
  description = "Per-app ECS TASK role ARN (runtime AWS access: SNS/SQS/S3/Cognito/SES/Secrets)."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group name for awslogs driver, e.g. /ecs/<name_prefix>/<name>."
  type        = string
}

variable "aws_region" {
  description = "Region (awslogs-region + appautoscaling)."
  type        = string
}

# --- ECS service / networking ---
variable "desired_count" {
  description = "Desired task count. For autoscaled services this is the initial/min seed."
  type        = number
  default     = 1
}

variable "subnet_ids" {
  description = "Subnets the Fargate ENIs land in (public when assign_public_ip=true; else private)."
  type        = list(string)
}

variable "task_security_group_ids" {
  description = "Security groups attached to the task ENI (the shared ECS task SG)."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Assign a public IP to the task ENI (true = NAT-less public-subnet Fargate)."
  type        = bool
  default     = true
}

# --- ALB wiring (web services only) ---
variable "needs_alb" {
  description = "Create a target group + listener rule and a load_balancer block. False for workers."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "VPC id for the target group. Required when needs_alb."
  type        = string
  default     = null
}

variable "alb_listener_arn" {
  description = "ARN of the shared HTTPS:443 listener to attach the host-header rule to. Required when needs_alb."
  type        = string
  default     = null
}

variable "listener_rule_priority" {
  description = "Unique priority for this service's host-header listener rule."
  type        = number
  default     = null
}

variable "host_header" {
  description = "Host the ALB rule matches, e.g. api.zopkit.com. Required when needs_alb."
  type        = string
  default     = null
}

variable "extra_host_headers" {
  description = "Additional host-header values merged into the listener rule condition (e.g. wrapper tenant wildcard *.<root>)."
  type        = list(string)
  default     = []
}

variable "health_check_path" {
  description = "Target group health check path, e.g. /health. Required when needs_alb."
  type        = string
  default     = "/"
}

variable "stickiness_enabled" {
  description = "Enable ALB cookie stickiness on the target group (wrapper /ws WebSocket)."
  type        = bool
  default     = false
}

variable "deregistration_delay" {
  description = "Target group deregistration delay seconds."
  type        = number
  default     = 30
}

# --- Autoscaling (web services that are leader-safe) ---
variable "autoscaling_enabled" {
  description = "Create an appautoscaling target + CPU target-tracking policy."
  type        = bool
  default     = false
}

variable "min_count" {
  description = "Autoscaling min task count."
  type        = number
  default     = 1
}

variable "max_count" {
  description = "Autoscaling max task count."
  type        = number
  default     = 1
}

variable "cpu_target_value" {
  description = "Target-tracking CPU utilization percentage."
  type        = number
  default     = 60
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
