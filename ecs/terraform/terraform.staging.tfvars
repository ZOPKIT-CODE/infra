# =============================================================================
# Zopkit Suite — ECS Fargate STAGING (cost-optimized for a startup)
#
# Use with the isolated staging workspace + this var-file:
#   terraform workspace select staging   # or: terraform workspace new staging
#   terraform plan  -var-file=terraform.staging.tfvars
#   terraform apply -var-file=terraform.staging.tfvars
#
# Cost shape (NAT-less public-subnet Fargate, 1 tiny Valkey, short logs):
#   - 4 Fargate tasks (3x 0.5vCPU/1GB web + 1x 0.25vCPU/0.5GB worker), all in
#     PUBLIC subnets with public IPs => NO NAT gateway ($0 NAT, ~$32/mo saved).
#   - 1x cache.t4g.micro Valkey, no replica (~$9/mo).
#   - ALB (~$16/mo) + minimal CloudWatch logs (7-day retention).
#   Estimated steady-state ≈ $80–110/mo 24/7; far less if run ephemerally
#   (apply to test, `terraform destroy` when done — Supabase + ECR persist).
#
# This stack reuses the AWS-native services (Cognito / SNS+SQS / S3+CloudFront /
# ECR / Secrets Manager / SES) VERBATIM from the EKS stack — only the compute
# layer differs. The EKS stack is left untouched.
# =============================================================================

project     = "zopkit"
environment = "staging"
aws_region  = "us-east-1"
data_region = "us-east-1"

# --- DNS (delegate this zone before a FULL apply; not needed for bootstrap) ---
root_domain         = "staging.zopkit.com"
create_route53_zone = false

# --- Networking: 2 AZs, NAT-LESS public-subnet Fargate -----------------------
# fargate_assign_public_ip = true => tasks get public IPs in PUBLIC subnets and
# pull images / reach AWS APIs directly, so NO NAT gateway is created at all
# (network.tf flips enable_nat_gateway off when public IPs are assigned).
vpc_cidr                 = "10.43.0.0/16" # distinct from prod's 10.42.0.0/16
az_count                 = 2              # ALB needs >=2 AZs; 2 is the cheap minimum
fargate_assign_public_ip = true           # NAT-less: tasks in public subnets w/ public IPs
single_nat_gateway       = true           # only relevant if you flip public_ip=false for prod-private

# --- Valkey: single tiny node, no replica (saves ~$90/mo vs medium+replica) --
valkey_node_type = "cache.t4g.micro" # ~$9/mo
valkey_replicas  = 0                 # single node, no Multi-AZ failover (fine for staging)

# --- Cognito (hosted-UI domain becomes "<prefix>-staging", globally unique) --
cognito_domain_prefix = "zopkit-platform-stg"

# --- Container images (CI pushes by SHA and force-new-deploys; latest = seed) -
image_tag = "latest"

# --- Ops: short log retention, no paid alerting, SES inbound OFF --------------
log_retention_days = 7
alarm_email        = ""
enable_ses_inbound = false
