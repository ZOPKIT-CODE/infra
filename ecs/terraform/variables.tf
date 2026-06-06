# ---------------------------------------------------------------------------
# Input variables. Copy terraform.tfvars.example -> terraform.tfvars and edit.
#
# This ECS Fargate stack drops all EKS/Kubernetes variables (kubernetes_version,
# node_*, cluster_*, enable_cluster_secret_store) and adds Fargate networking +
# optional per-service override maps.
# ---------------------------------------------------------------------------

variable "project" {
  description = "Project/name prefix for all resources."
  type        = string
  default     = "zopkit"
}

variable "environment" {
  description = "Environment name (prod, staging). Used in name prefixes."
  type        = string
  default     = "staging"
}

variable "aws_region" {
  description = "Primary AWS region (ECS, ALB, SNS/SQS, ElastiCache, Cognito, Secrets)."
  type        = string
  default     = "us-east-1"
}

variable "data_region" {
  description = "ADVISORY ONLY for now. All S3 buckets + SES are currently created in aws_region (a single for_each cannot switch providers per element). To physically place CRM/FA storage in a different region, split crm_attachments/fa_receipts/ses_inbound into their own resources under the aws.crm_data provider (see the comment in s3.tf) — until then keep this equal to aws_region. The apps' S3 SDK uses AWS_REGION=aws_region."
  type        = string
  default     = "us-east-1"
}

variable "root_domain" {
  description = "Root domain. The hosted zone is looked up (must already exist in Route53) unless create_route53_zone=true."
  type        = string
  default     = "zopkit.com"
}

variable "create_route53_zone" {
  description = "Create the Route53 public hosted zone (true) or look up an existing one (false)."
  type        = bool
  default     = false
}

# --- Networking ---
variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.42.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones (>=2 for HA, 3 recommended)."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "When NAT is enabled (fargate_assign_public_ip = false), use a single NAT gateway (cheaper, non-HA) instead of one per AZ."
  type        = bool
  default     = false
}

# --- Fargate networking ---
variable "fargate_assign_public_ip" {
  description = "Place Fargate tasks in PUBLIC subnets with a public IP and NO NAT gateway (cheapest — good for staging). Set false to run tasks in PRIVATE subnets behind NAT (prod-private)."
  type        = bool
  default     = true
}

# --- Per-service overrides (optional; empty = use the in-locals defaults) ---
variable "service_desired_count_overrides" {
  description = "Override desired_count per ECS service (keyed by service name, e.g. wrapper-web). Empty map = use local.services defaults."
  type        = map(number)
  default     = {}
}

variable "service_cpu_overrides" {
  description = "Override Fargate CPU units per ECS service (keyed by service name). Empty map = use local.services defaults."
  type        = map(number)
  default     = {}
}

variable "service_memory_overrides" {
  description = "Override Fargate memory (MiB) per ECS service (keyed by service name). Empty map = use local.services defaults."
  type        = map(number)
  default     = {}
}

# --- ElastiCache Valkey ---
variable "valkey_node_type" {
  description = "ElastiCache (Valkey) node type."
  type        = string
  default     = "cache.t4g.medium"
}

variable "valkey_replicas" {
  description = "Number of replica nodes (read replicas / failover). 1+ enables Multi-AZ."
  type        = number
  default     = 1
}

# --- Cognito ---
variable "cognito_domain_prefix" {
  description = "Cognito hosted-UI domain prefix (must be globally unique)."
  type        = string
  default     = "zopkit-platform"
}

# --- Container images (set by CI; placeholders until first push) ---
variable "image_tag" {
  description = "Default container image tag deployed to every ECS service (overridden per-service by CI)."
  type        = string
  default     = "latest"
}

# Per-service image tag overrides, keyed by service name (wrapper-web, crm-web,
# fa-web, fa-consumer). Any service not present falls back to var.image_tag.
# This is what makes a true one-app-at-a-time rollout possible: bump only
# `wrapper-web` to a new SHA and apply, without needing fresh images for the
# others. deploy-service.sh sets this automatically.
variable "service_image_tags" {
  description = "Per-service image tag overrides, keyed by ECS service name. Missing services fall back to var.image_tag."
  type        = map(string)
  default     = {}
}

# --- Operational ---
variable "log_retention_days" {
  description = "CloudWatch log group retention."
  type        = number
  default     = 30
}

variable "alarm_email" {
  description = "Email subscribed to the ops SNS alarm topic (DLQ depth, etc.). Empty = skip."
  type        = string
  default     = ""
}

variable "enable_ses_inbound" {
  description = "Provision the CRM SES inbound-email pipeline (S3 -> Lambda -> CRM webhook). OFF by default — it needs SES domain verification + MX records and the handler deps bundled. See ses_inbound.tf."
  type        = bool
  default     = false
}
