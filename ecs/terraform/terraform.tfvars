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
# alarm_email = ""   # set to route DLQ / ops alarms to an inbox

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
rds_publicly_accessible = true
rds_admin_cidrs         = ["157.50.86.215/32"]

# Mathesar URL SSO gate — ALB requires Cognito login before reaching Mathesar
# (works on CGNAT; no IP allow-list). Uses a DEDICATED internal-tools pool
# (us-east-1_OtYJMnHdE) that is ADMIN-CREATE-ONLY + no Google — so ONLY accounts
# an admin creates (the dev team) can pass the gate, not any public/self-signup
# user. (The customer-facing app keeps the shared zopkit-platform pool.)
mathesar_cognito_user_pool_arn = "arn:aws:cognito-idp:us-east-1:207567767101:userpool/us-east-1_OtYJMnHdE"
mathesar_cognito_client_id     = "297e5sbe4343mu2lb39p6hd2vi"
mathesar_cognito_domain        = "zopkit-internal-tools"
