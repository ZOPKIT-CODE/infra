# First environment: STAGING (validate the pipeline before prod). See deploy/PLAYBOOK.md.
# name_prefix = "${project}-${environment}" = zopkit-staging
project     = "zopkit"
environment = "staging"
aws_region  = "us-east-1"
data_region = "us-east-1"
# Staging uses its OWN subdomain so it never collides with the LIVE zopkit.com
# records (app/crm/accounting all already point at old infra). All hostnames
# become *.staging.zopkit.com. create_route53_zone makes a new staging zone;
# delegation.tf wires the NS delegation from the parent zopkit.com zone.
root_domain         = "staging.zopkit.com"
create_route53_zone = true

# Network: public-IP, NO NAT (EIP quota is maxed at 5/5; var docs call this
# "good for staging"). Tasks sit in public subnets, still SG-firewalled.
# Switch prod to private+NAT after an EIP quota increase.
fargate_assign_public_ip = true
single_nat_gateway       = true # ignored when fargate_assign_public_ip=true (no NAT)

# image_tag stays "latest" until the first push; deploy-service.sh sets immutable
# per-service SHA tags via image-tags.auto.tfvars.json.
# Ops alarms (DLQ-not-empty etc.) — confirm the SNS subscription from the inbox after apply.
alarm_email = "zopkitrock@gmail.com"

# Reuse the shared zopkit-platform Cognito pool (Google federation + clients already set up)
cognito_user_pool_id           = "us-east-1_6e8AY4eMj"
cognito_existing_domain_prefix = "zopkit-platform-ay4emj"
cognito_client_ids = {
  wrapper = "744sfndqk37c2eeq55k2c0oe10"
  crm     = "shhqqu2i3ali7vccmd9gipcac"
  fa      = "lu29k9dvm7vn69qggvklt51ka"
}

# Staging: skip the credit/trial gate so the app is usable (the dev tenant has 0 credits)
bypass_trial_restrictions = true

# Reuse the shared dev logo/blog-media bucket (matches the shared dev DB image keys)
logo_bucket_override = "wrapper-tenant-logos"

# --- RDS (staging trial: wrapper first) ---
# One t4g.micro hosting per-app staging databases. publicly_accessible for dev
# convenience, SG-locked to the ECS tasks + the admin IP below. Prod will use a
# separate instance, private (publicly_accessible=false, rds_admin_cidrs=[]).
enable_rds              = true
enable_mathesar         = true
rds_publicly_accessible = true
rds_admin_cidrs         = ["157.50.86.215/32"]

# Mathesar SSO gate DISABLED — single login via Mathesar's own accounts instead
# of the ALB Cognito gate (Mathesar's native OIDC is still WIP upstream, so a
# clean single Cognito login isn't available). Access is gated by Mathesar's
# login; admins create dev accounts in Mathesar (Administration → Users). Re-enable
# the ALB Cognito gate by setting these to a pool/client/domain again.
mathesar_cognito_user_pool_arn = ""
mathesar_cognito_client_id     = ""
mathesar_cognito_domain        = ""
