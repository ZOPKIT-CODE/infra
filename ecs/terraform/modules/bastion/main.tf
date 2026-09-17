data "aws_ami" "al2023" {
  count       = var.enabled ? 1 : 0
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_iam_role" "bastion" {
  count = var.enabled ? 1 : 0
  name  = "${var.name_prefix}-bastion"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count      = var.enabled ? 1 : 0
  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.enabled ? 1 : 0
  name  = "${var.name_prefix}-bastion"
  role  = aws_iam_role.bastion[0].name
}

resource "aws_security_group" "bastion" {
  count       = var.enabled ? 1 : 0
  name        = "${var.name_prefix}-bastion"
  description = "SSM bastion - no inbound; egress for SSM + RDS"
  vpc_id      = var.vpc_id
  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name_prefix}-bastion" }
}

resource "aws_instance" "bastion" {
  count                       = var.enabled ? 1 : 0
  ami                         = data.aws_ami.al2023[0].id
  instance_type               = "t4g.nano"
  iam_instance_profile        = aws_iam_instance_profile.bastion[0].name
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.bastion[0].id]
  associate_public_ip_address = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y amazon-ssm-agent || yum install -y amazon-ssm-agent || true
    systemctl enable --now amazon-ssm-agent || true
  EOF

  tags = { Name = "${var.name_prefix}-bastion" }
}
