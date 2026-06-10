# PRODUCTION env (Terraform workspace "prod" → state at env:/prod/suite-ecs/...).
# Stands up prod ECS on zopkit.com, mirroring the staging build. Apply with:
#   terraform workspace select prod && terraform apply -var-file=terraform.prod.tfvars
#
# CUTOVER IS PHASED via manage_apex_dns:
#   Wave 1 (build+validate, ZERO DNS impact): manage_apex_dns = false  (current)
#   Wave 2 (flip live traffic):               manage_apex_dns = true
# The legacy EC2 box (i-085cb714d4af4a499 / EIP 35.171.71.112) stays up as rollback
# until prod is soaked, then is decommissioned.
project     = "zopkit"
environment = "prod"
aws_region  = "us-east-1"
data_region = "us-east-1"

# Real apex domain. The zopkit.com hosted zone already exists (registrar-managed),
# so look it up rather than create it.
root_domain         = "zopkit.com"
create_route53_zone = false

# WAVE 2 (cutover): create the live apex records. Scoped to wrapper only:
#   - dns_only_live_apps=true  -> NO crm./accounting. records (crm.zopkit.com is a
#     live CRM on another ALB; only wrapper-web is enabled in prod).
#   - apex_frontend_app="wrapper" -> zopkit.com (apex) ALSO serves the wrapper SPA.
# Records created (allow_overwrite): zopkit.com + app.zopkit.com -> CloudFront,
# api.zopkit.com -> ALB, *.zopkit.com -> ALB. The legacy EC2 box stays up as rollback.
manage_apex_dns    = true
dns_only_live_apps = true
apex_frontend_app  = "wrapper"

# Same networking posture as staging (public-IP, no NAT) until an EIP-quota increase
# lets prod move to private subnets + NAT.
fargate_assign_public_ip = true
single_nat_gateway       = true

# Reuse the shared zopkit-platform Cognito pool (Google federation + clients already
# configured). The prod apex callback URLs (https://api.zopkit.com/api/auth/callback,
# https://app.zopkit.com) are appended to the shared wrapper client out-of-band.
cognito_user_pool_id           = "us-east-1_6e8AY4eMj"
cognito_existing_domain_prefix = "zopkit-platform-ay4emj"
cognito_client_ids = {
  wrapper = "744sfndqk37c2eeq55k2c0oe10"
  crm     = "shhqqu2i3ali7vccmd9gipcac"
  fa      = "lu29k9dvm7vn69qggvklt51ka"
}

# TEMPORARY: prod points at the STAGING database for now (per request — "use the
# staging db as of now, then I will change it"). Because that shared dev DB's tenant
# has 0 credits, keep the trial gate bypassed so the app is usable. Revisit BOTH of
# these when prod gets its own database.
bypass_trial_restrictions = true

# Reuse the shared logo/blog-media bucket (matches the shared DB's image keys).
logo_bucket_override = "wrapper-tenant-logos"

# The GitHub Actions OIDC provider is an account-wide singleton owned by the
# staging (default) workspace. Prod must NOT manage it (so destroying prod can't
# delete the shared CI principal). Prod has no CI automation yet; add a prod deploy
# role later referencing the existing provider via a data source.
enable_ci_oidc = false

# ECR repos are shared (not env-prefixed) and owned by the staging/default workspace.
# Prod references the same images rather than recreating the repos.
manage_ecr = false

# --- PROD RDS (dedicated, private instance in the prod VPC) ---
# Cutover off Supabase. Private (publicly_accessible=false → intra subnets, reach
# via SSM bastion), prod-grade (deletion protection + final snapshot). Mathesar is
# NOT deployed in prod (enable_mathesar defaults false — no public DB UI).
enable_rds              = true
rds_publicly_accessible = false
rds_admin_cidrs         = []
rds_instance_class      = "db.t4g.small"
rds_deletion_protection = true
rds_skip_final_snapshot = false

enable_mathesar         = false   # NO public DB UI in prod
