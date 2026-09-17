resource "random_password" "rds_master" {
  count   = var.enable_rds ? 1 : 0
  length  = 40
  special = false
}

resource "aws_security_group" "rds" {
  count       = var.enable_rds ? 1 : 0
  name        = "${local.name_prefix}-rds"
  description = "Postgres access from ECS Fargate tasks + admin allow-list"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Postgres from ECS task security group"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }

  dynamic "ingress" {
    for_each = var.enable_bastion ? [1] : []
    content {
      description     = "Postgres from SSM bastion"
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = [aws_security_group.bastion[0].id]
    }
  }

  dynamic "ingress" {
    for_each = var.rds_admin_cidrs
    content {
      description = "Postgres from admin allow-list"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-rds" }
}

resource "aws_db_subnet_group" "this" {
  count      = var.enable_rds ? 1 : 0
  name       = "${local.name_prefix}-db"
  subnet_ids = var.rds_publicly_accessible ? module.vpc.public_subnets : module.vpc.intra_subnets
  tags       = { Name = "${local.name_prefix}-db" }
}

resource "aws_db_instance" "this" {
  count      = var.enable_rds ? 1 : 0
  identifier = "${local.name_prefix}-db"

  engine         = "postgres"
  engine_version = "15.8"
  instance_class = var.rds_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  username = "dbadmin"
  password = random_password.rds_master[0].result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  publicly_accessible    = var.rds_publicly_accessible

  backup_retention_period      = 7
  copy_tags_to_snapshot        = true
  performance_insights_enabled = true

  apply_immediately         = true
  skip_final_snapshot       = var.rds_skip_final_snapshot
  final_snapshot_identifier = var.rds_skip_final_snapshot ? null : "${local.name_prefix}-db-final"
  deletion_protection       = var.rds_deletion_protection

  auto_minor_version_upgrade = true

  tags = { Name = "${local.name_prefix}-db" }
}

resource "aws_secretsmanager_secret" "rds_master" {
  count = var.enable_rds ? 1 : 0
  name  = "zopkit/${var.environment}/rds-master"
  tags  = local.common_tags
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  count     = var.enable_rds ? 1 : 0
  secret_id = aws_secretsmanager_secret.rds_master[0].id
  secret_string = jsonencode({
    host     = aws_db_instance.this[0].address
    port     = 5432
    username = "dbadmin"
    password = random_password.rds_master[0].result
    url      = "postgresql://dbadmin:${random_password.rds_master[0].result}@${aws_db_instance.this[0].address}:5432/postgres?sslmode=require"
  })
}

output "rds_endpoint" {
  description = "RDS instance endpoint (host:port). Null when enable_rds=false."
  value       = one(aws_db_instance.this[*].endpoint)
}
