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

variable "dns_only_live_apps" {
  description = "Create apex frontend/api DNS records only for apps whose <app>-web service is enabled. Use in partial-rollout envs (e.g. prod with only wrapper live) so crm./accounting. records aren't pointed at empty resources or made to clobber another stack's DNS. Default false = records for all apps (prior behavior)."
  type        = bool
  default     = false
}

variable "apex_frontend_app" {
  description = "App key (e.g. \"wrapper\") whose CloudFront distribution ALSO serves the bare apex root_domain, plus an apex A-alias record. Empty = no app serves the apex. The cloudfront ACM cert already covers the apex (it SANs root_domain + *.root_domain)."
  type        = string
  default     = ""
}

variable "manage_apex_dns" {
  description = <<-EOT
    Whether to create the live apex A-records (app/api/<root> + the *.<root> tenant
    wildcard) that point real traffic at this env's CloudFront/ALB. Set false to
    stand up an environment WITHOUT touching DNS (build + validate first), then set
    true to perform the cutover. ACM-validation CNAMEs are always managed (they only
    add validation records, never move traffic). Default true preserves prior
    single-env behavior. The apex records carry allow_overwrite=true so the cutover
    safely replaces any pre-existing records (e.g. a legacy box's A-records).
  EOT
  type        = bool
  default     = true
}

variable "create_route53_zone" {
  description = "Create the Route53 public hosted zone (true) or look up an existing one (false)."
  type        = bool
  default     = false
}

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

variable "fargate_assign_public_ip" {
  description = "Place Fargate tasks in PUBLIC subnets with a public IP and NO NAT gateway (cheapest — good for staging). Set false to run tasks in PRIVATE subnets behind NAT (prod-private)."
  type        = bool
  default     = true
}

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

variable "service_enabled_overrides" {
  description = "Override the enabled flag per ECS service (keyed by service name, e.g. lens-web). Empty map = use local.services defaults."
  type        = map(bool)
  default     = {}
}

variable "disabled_frontends" {
  description = "Frontend keys to exclude in this environment. Empty = all frontends in local.frontends are created."
  type        = set(string)
  default     = []
}

variable "valkey_node_type" {
  description = "ElastiCache (Valkey) node type."
  type        = string
  default     = "cache.t4g.micro"
}

variable "valkey_replicas" {
  description = "Number of replica nodes (read replicas / failover). 1+ enables Multi-AZ."
  type        = number
  default     = 1
}

variable "cognito_domain_prefix" {
  description = "Cognito hosted-UI domain prefix (must be globally unique)."
  type        = string
  default     = "zopkit-platform"
}

variable "image_tag" {
  description = "Default container image tag deployed to every ECS service (overridden per-service by CI)."
  type        = string
  default     = "latest"
}

variable "service_image_tags" {
  description = "Per-service image tag overrides, keyed by ECS service name. Missing services fall back to var.image_tag."
  type        = map(string)
  default     = {}
}

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
  description = "Provision the CRM SES inbound-email pipeline (S3 -> Lambda -> CRM webhook). OFF by default — it needs SES domain verification + MX records and the handler deps bundled. The pipeline itself is not vendored into this stack."
  type        = bool
  default     = false
}

variable "cognito_user_pool_id" {
  description = "Existing Cognito user pool id to reuse (e.g. the shared zopkit-platform pool). Empty = create+use this stack's own pool."
  type        = string
  default     = ""
}

variable "cognito_existing_domain_prefix" {
  description = "Domain PREFIX of the EXISTING pool being reused (e.g. zopkit-platform-ay4emj). Empty = use this stack's created domain."
  type        = string
  default     = ""
}

variable "cognito_client_ids" {
  description = "Per-app app-client id override, keyed by app (wrapper|crm|fa). Missing app falls back to this stack's created client."
  type        = map(string)
  default     = {}
}

variable "bypass_trial_restrictions" {
  description = "When true, sets BYPASS_TRIAL_RESTRICTIONS=true so the credit/trial gate is skipped (staging/test). Keep false for prod."
  type        = bool
  default     = false
}

variable "logo_bucket_override" {
  description = "Existing S3 bucket for logos/blog media to use instead of this stack's created one (so images referenced by a shared DB resolve). Empty = use the created bucket."
  type        = string
  default     = ""
}

variable "enable_valkey" {
  description = "Manage the shared Valkey (Redis-compatible) ElastiCache replication group. Set false to stop paying for it while no app hard-requires caching (e.g. a no-real-users testing phase) - REDIS_ENABLED and the REDIS_URL/REDIS_PASSWORD secret injection are dropped for every app when false, so apps degrade to no-cache rather than failing to find a missing secret. Re-enable and re-apply to recreate."
  type        = bool
  default     = true
}

variable "github_deploy_repos" {
  description = "owner/repo allowed to assume the deploy role via OIDC."
  type        = list(string)
  default = [
    "ZOPKIT-CODE/Wrapper",
    "ZOPKIT-CODE/B2B-CRM",
    "ZOPKIT-CODE/Finance-Accounting",
    "ursrudra/zopkit-lens",
    "ZOPKIT-CODE/zopkit-lens",
    "Zopkit/Zopkit-Academy",
    "ZOPKIT-CODE/Entertainment-erp",
    "ZOPKIT-CODE/infra",
  ]
}

variable "enable_ci_oidc" {
  description = <<-EOT
    Manage the GitHub Actions OIDC provider + deploy role in THIS environment.
    The OIDC provider is an account-wide singleton, so exactly ONE environment may
    own it — keep true for the primary (staging/default) env and false elsewhere
    (e.g. prod) so a `terraform destroy` of a secondary env can never delete the
    shared CI principal. A secondary env that later needs its own deploy role can
    add a role that references the existing provider via a data source.
  EOT
  type        = bool
  default     = true
}

variable "mutable_tag_repos" {
  description = "ECR repositories still publishing a moving tag, so they must stay MUTABLE. Remove an entry once its build emits git-SHA tags — see deploy/ecs/ONBOARDING.md."
  type        = set(string)
  default     = ["entertainment-erp-backend"]
}

variable "manage_ecr" {
  description = "Create the shared ECR repositories (true) or look them up (false). One env owns them; secondary envs (e.g. prod) reference the same images."
  type        = bool
  default     = true
}

variable "enable_rds" {
  description = "Provision the RDS Postgres instance in this environment."
  type        = bool
  default     = false
}

variable "rds_instance_class" {
  description = "RDS instance class. t4g.micro for staging; bump to t4g.medium for a prod instance hosting several app DBs."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_admin_cidrs" {
  description = "Admin IP CIDRs allowed to reach the staging DB directly (for seeding + GUI/MCP). Empty = ECS-tasks-only. Use [] for prod (private)."
  type        = list(string)
  default     = []
}

variable "enable_bastion" {
  description = <<-EOT
    Create the SSM bastion (EC2 + IAM role/profile + SG) used to port-forward to a
    PRIVATE RDS. Off: the staging RDS is publicly accessible and db-tunnel.sh /
    mcp-db.sh connect to it directly via the rds_admin_cidrs allow-list — no bastion
    in the path. Both environments' bastion instances were terminated out-of-band
    well before this flag existed, so leaving it off matches reality. Turn it back
    on only if RDS moves to private subnets (rds_publicly_accessible = false).
  EOT
  type        = bool
  default     = false
}

variable "rds_publicly_accessible" {
  description = "Staging convenience (true) vs prod security (false → private subnets, reach via SSM/VPN)."
  type        = bool
  default     = false
}

variable "rds_deletion_protection" {
  description = "Protect the DB from accidental deletion (true for prod)."
  type        = bool
  default     = false
}

variable "rds_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy (true for staging convenience; FALSE for prod)."
  type        = bool
  default     = true
}

variable "enable_mathesar" {
  description = "Deploy the Mathesar UI (staging only by default; keep OFF in prod — no public DB UI)."
  type        = bool
  default     = false
}

variable "mathesar_cognito_user_pool_arn" {
  description = "Cognito user pool ARN for the Mathesar ALB SSO gate. Empty = no SSO."
  type        = string
  default     = ""
}

variable "mathesar_cognito_client_id" {
  description = "Cognito app client id (with a secret + the /oauth2/idpresponse callback) for the ALB SSO gate."
  type        = string
  default     = ""
}

variable "mathesar_cognito_domain" {
  description = "Cognito hosted-UI domain PREFIX for the ALB SSO gate."
  type        = string
  default     = ""
}
