variable "name_prefix" {
  description = "Resource name prefix, \"<project>-<environment>\"."
  type        = string
}

variable "enabled" {
  description = "Create the SSM bastion. Off by default — the staging RDS is publicly reachable, so nothing needs it."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "VPC the bastion instance and its security group live in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets; the instance is placed in the first one."
  type        = list(string)
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
