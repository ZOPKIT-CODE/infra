# Root module for the prod environment.
#
# The backend key points at the state object the `prod` WORKSPACE already
# uses, so this directory ADOPTS the prod workspace's existing state object rather
# than migrating it. Terraform stores workspace state at "env:/<workspace>/<key>",
# which is just an S3 object key — nothing needs to be moved or re-imported.
#
# Do not run `terraform workspace select` here. The directory IS the environment.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.60" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }

  backend "s3" {
    bucket       = "zopkit-tfstate-207567767101"
    key          = "env:/prod/suite-ecs/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
