# Provider + version constraints for the shared suite stack.
#
# This module is instantiated once per environment from ../../environments/<env>.
# It declares NO provider configuration and NO backend — both belong to the root
# module — but it does declare the aliases it expects to be handed, so a root
# that forgets to pass them fails at init rather than at apply.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.60"
      configuration_aliases = [aws.us_east_1, aws.crm_data]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
