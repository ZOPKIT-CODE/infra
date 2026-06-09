# bastion.tf — tiny SSM-managed bastion for secure dev/MCP access to the private
# RDS. No SSH keys, no inbound ports: connect via AWS Systems Manager Session
# Manager (IAM-gated, CloudTrail-audited) and port-forward localhost:5432 → RDS:
#
#   aws ssm start-session --target <instance-id> \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters '{"host":["<rds-endpoint>"],"portNumber":["5432"],"localPortNumber":["5432"]}'
#
# Then point psql / a GUI / a Postgres MCP at localhost:5432. Gated by var.enable_rds.

data "aws_ami" "al2023" {
  count       = var.enable_rds ? 1 : 0
  most_recent = true
  owners      = ["amazon"]
  filter {
    name = "name"
    # STANDARD AL2023 (NOT al2023-ami-minimal-*, which omits the SSM agent and
    # never registers with Session Manager). The standard image ships + enables
    # amazon-ssm-agent by default.
    values = ["al2023-ami-2023.*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_iam_role" "bastion" {
  count = var.enable_rds ? 1 : 0
  name  = "${local.name_prefix}-bastion"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

# SSM core managed policy = Session Manager connectivity (no SSH, no inbound).
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count      = var.enable_rds ? 1 : 0
  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.enable_rds ? 1 : 0
  name  = "${local.name_prefix}-bastion"
  role  = aws_iam_role.bastion[0].name
}

# Bastion SG: NO inbound (SSM is outbound-initiated). Egress all (reach SSM + RDS).
resource "aws_security_group" "bastion" {
  count       = var.enable_rds ? 1 : 0
  name        = "${local.name_prefix}-bastion"
  description = "SSM bastion - no inbound; egress for SSM + RDS"
  vpc_id      = module.vpc.vpc_id
  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name_prefix}-bastion" }
}

# Let the bastion reach RDS on 5432.
resource "aws_security_group_rule" "rds_from_bastion" {
  count                    = var.enable_rds ? 1 : 0
  type                     = "ingress"
  description              = "Postgres from SSM bastion"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds[0].id
  source_security_group_id = aws_security_group.bastion[0].id
}

resource "aws_instance" "bastion" {
  count                       = var.enable_rds ? 1 : 0
  ami                         = data.aws_ami.al2023[0].id
  instance_type               = "t4g.nano"
  iam_instance_profile        = aws_iam_instance_profile.bastion[0].name
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.bastion[0].id]
  associate_public_ip_address = true # reach the SSM service (no NAT in staging)

  metadata_options {
    http_tokens   = "required" # IMDSv2
    http_endpoint = "enabled"
  }

  # Belt-and-suspenders: ensure the SSM agent is installed + running regardless
  # of the AMI variant. Triggers a replacement when changed.
  user_data = <<-EOF
    #!/bin/bash
    dnf install -y amazon-ssm-agent || yum install -y amazon-ssm-agent || true
    systemctl enable --now amazon-ssm-agent || true
  EOF

  tags = { Name = "${local.name_prefix}-bastion" }
}

output "bastion_instance_id" {
  description = "SSM bastion instance id — `aws ssm start-session --target <id>` to port-forward to RDS."
  value       = one(aws_instance.bastion[*].id)
}
