# Provider CONFIGURATION lives in the root module (environments/<env>/providers.tf).
# A shared module must not configure providers of its own — it receives them,
# including the aws.us_east_1 and aws.crm_data aliases declared in versions.tf.

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}
