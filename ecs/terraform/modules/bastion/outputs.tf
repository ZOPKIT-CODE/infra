output "bastion_instance_id" {
  description = "SSM bastion instance id — `aws ssm start-session --target <id>` to port-forward to RDS."
  value       = one(aws_instance.bastion[*].id)
}
