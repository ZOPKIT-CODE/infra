# ---------------------------------------------------------------------------
# Input variables. Copy terraform.tfvars.example -> terraform.tfvars and edit.
# ---------------------------------------------------------------------------

variable "project" {
  description = "Project/name prefix for all resources."
  type        = string
  default     = "zopkit"
}

variable "environment" {
  description = "Environment name (prod, staging). Used in name prefixes + namespace."
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "Primary AWS region (EKS, SNS/SQS, ElastiCache, Cognito, ALB)."
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
  description = "Use a single NAT gateway (cheaper, non-HA) instead of one per AZ."
  type        = bool
  default     = false
}

# --- EKS ---
variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "Instance types for the default managed node group."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_group_min" {
  description = "Min nodes in the default managed node group."
  type        = number
  default     = 3
}

variable "node_group_max" {
  description = "Max nodes in the default managed node group."
  type        = number
  default     = 8
}

variable "node_group_desired" {
  description = "Desired nodes in the default managed node group."
  type        = number
  default     = 3
}

variable "node_capacity_type" {
  description = "EKS managed node group capacity type: ON_DEMAND (stable, prod) or SPOT (up to ~70% cheaper, may be reclaimed — good for staging/dev). For SPOT, set node_instance_types to several comparable types to improve availability."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "cluster_admin_role_arns" {
  description = "Additional IAM role ARNs granted cluster-admin (access entries)."
  type        = list(string)
  default     = []
}

variable "cluster_public_access" {
  description = "Expose the EKS public API endpoint (restrict via cluster_public_access_cidrs)."
  type        = bool
  default     = true
}

variable "cluster_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
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

variable "cognito_platform_admin_group" {
  description = "Cognito group whose members are internal platform admins (cross-tenant plane). Surfaced via the cognito:groups claim; read by the backend as COGNITO_PLATFORM_ADMIN_GROUP."
  type        = string
  default     = "platform-admins"
}

# --- Container images (set by CI; placeholders until first push) ---
variable "image_tag" {
  description = "Default container image tag deployed (overridden per-app by CI / Helm)."
  type        = string
  default     = "latest"
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

variable "enable_cluster_secret_store" {
  description = "Create the ExternalSecrets ClusterSecretStore (kubernetes_manifest). MUST be false on the FIRST apply (the ESO CRDs do not exist yet, and kubernetes_manifest validates against the live cluster at plan time). Set true on the SECOND apply, once external-secrets is installed. See README 'Apply order'."
  type        = bool
  default     = false
}
