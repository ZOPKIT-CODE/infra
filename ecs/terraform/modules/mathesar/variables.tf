variable "name_prefix" {
  description = "Resource name prefix, \"<project>-<environment>\"."
  type        = string
}

variable "enabled" {
  description = "Create the Mathesar service. Root passes enable_mathesar && enable_rds."
  type        = bool
  default     = false
}

variable "environment" {
  description = "Environment name (staging | prod)."
  type        = string
}

variable "aws_region" {
  description = "Region for the awslogs driver."
  type        = string
}

variable "root_domain" {
  description = "Root domain; the UI is served at mathesar.<root_domain>."
  type        = string
}

variable "route53_zone_id" {
  description = "Hosted zone the mathesar A record is created in."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the target group."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets; used when fargate_assign_public_ip = false."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets; used when fargate_assign_public_ip = true."
  type        = list(string)
}

variable "fargate_assign_public_ip" {
  description = "Place the task in public subnets with a public IP (NAT-less) rather than private subnets."
  type        = bool
}

variable "cluster_id" {
  description = "ECS cluster to run the service on."
  type        = string
}

variable "execution_role_arn" {
  description = "Shared ECS execution role."
  type        = string
}

variable "alb_listener_arn" {
  description = "HTTPS listener the host-header rule is attached to."
  type        = string
}

variable "alb_dns_name" {
  description = "ALB DNS name, for the Route53 alias record."
  type        = string
}

variable "alb_zone_id" {
  description = "ALB hosted zone ID, for the Route53 alias record."
  type        = string
}

variable "alb_security_group_id" {
  description = "ALB security group — the source of the task ingress rule."
  type        = string
}

variable "tasks_security_group_id" {
  description = "Shared ECS task security group. Mathesar's port is not in local.services, so its ingress rule is added explicitly."
  type        = string
}

variable "db_address" {
  description = "RDS instance address (hostname, no port)."
  type        = string
}

variable "mathesar_cognito_user_pool_arn" {
  description = "Cognito pool ARN for ALB authenticate-cognito. Empty disables ALB auth."
  type        = string
  default     = ""
}

variable "mathesar_cognito_client_id" {
  description = "Cognito app client ID for ALB authenticate-cognito."
  type        = string
  default     = ""
}

variable "mathesar_cognito_domain" {
  description = "Cognito hosted-UI domain for ALB authenticate-cognito."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
