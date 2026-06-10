# =============================================================================
# Zopkit Suite — STAGING (cost-optimized for a startup)
# Use with the isolated staging workspace:
#   terraform workspace select staging
#   terraform plan  -var-file=terraform.staging.tfvars
#   terraform apply -var-file=terraform.staging.tfvars
# Estimated steady-state cost ≈ $150/mo 24/7, or ≈ $20–40/mo if run ephemerally
# (apply to test, `terraform destroy` when done — Supabase + ECR persist).
# =============================================================================

project     = "zopkit"
environment = "staging"
aws_region  = "us-east-1"
data_region = "us-east-1"

# --- DNS (delegate this zone before a FULL apply; not needed for bootstrap) ---
root_domain         = "staging.zopkit.com"
create_route53_zone = false

# --- Networking: 2 AZs + ONE NAT gateway (saves ~$65/mo vs 3 NATs) -----------
vpc_cidr           = "10.43.0.0/16"   # distinct from prod's 10.42.0.0/16
az_count           = 2                 # EKS needs >=2; 2 is the cheap minimum
single_nat_gateway = true              # 1 NAT instead of one-per-AZ  → ~$32/mo not ~$97/mo

# --- EKS: SPOT nodes, small + few (saves ~70% on compute) --------------------
kubernetes_version  = "1.30"
node_capacity_type  = "SPOT"                                  # ~70% cheaper than ON_DEMAND
node_instance_types = ["t3.large", "t3a.large", "t3.medium", "t3a.medium"] # mixed = better SPOT availability
node_group_min      = 1
node_group_desired  = 2                # ~2 small spot nodes fit the 4 app pods + addons
node_group_max      = 3

# Lock the public EKS API to your IP/VPN/CI (NOT 0.0.0.0/0). The applying
# principal already gets cluster-admin (enable_cluster_creator_admin_permissions),
# so cluster_admin_role_arns can stay empty for a solo operator.
cluster_public_access       = true
cluster_public_access_cidrs = ["0.0.0.0/0"] # TODO: replace with "<your-ip>/32"
cluster_admin_role_arns     = []

# --- Valkey: single tiny node, no replica (saves ~$90/mo vs medium+replica) --
valkey_node_type = "cache.t4g.micro"   # ~$9/mo
valkey_replicas  = 0                    # single node, no Multi-AZ failover (fine for staging)

# --- Cognito (hosted-UI domain becomes "<prefix>-staging", globally unique) --
cognito_domain_prefix = "zopkit-platform-stg"

# --- Ops: short log retention, no paid alerting, SES inbound OFF -------------
log_retention_days = 7
alarm_email        = ""
enable_ses_inbound = false
