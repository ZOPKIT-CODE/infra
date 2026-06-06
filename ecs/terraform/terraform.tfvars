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
