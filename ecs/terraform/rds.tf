# rds.tf — RDS PostgreSQL for the suite (one instance hosting per-app databases).
#
# Gated by var.enable_rds so it only provisions where opted in (staging first).
# Staging posture: publicly_accessible = true but SG-locked to the ECS tasks SG +
# an admin allow-list CIDR, so devs/seeding can reach it. PROD should flip
# publicly_accessible=false and live in private subnets (see comments).
#
# One instance hosts all app databases (wrapper_<env>, crm_<env>, …); each app
# gets its own database + least-privilege roles, created out-of-band after apply.

variable "enable_rds" {
  description = "Provision the RDS Postgres instance in this environment."
  type        = bool
  default     = false
}

variable "rds_instance_class" {
  description = "RDS instance class. t4g.micro for staging; bump to t4g.medium for a prod instance hosting several app DBs."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_admin_cidrs" {
  description = "Admin IP CIDRs allowed to reach the staging DB directly (for seeding + GUI/MCP). Empty = ECS-tasks-only. Use [] for prod (private)."
  type        = list(string)
  default     = []
}

variable "rds_publicly_accessible" {
  description = "Staging convenience (true) vs prod security (false → private subnets, reach via SSM/VPN)."
  type        = bool
  default     = false
}


variable "rds_deletion_protection" {
  description = "Protect the DB from accidental deletion (true for prod)."
  type        = bool
  default     = false
}

variable "rds_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy (true for staging convenience; FALSE for prod)."
  type        = bool
  default     = true
}

# Master/superuser password — used only to create per-app databases + roles.
resource "random_password" "rds_master" {
  count   = var.enable_rds ? 1 : 0
  length  = 40
  special = false
}

# Security group: 5432 from the ECS tasks SG (apps) + admin CIDRs (seeding/GUI).
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

  # INLINE (not a separate aws_security_group_rule): this SG uses inline ingress
  # blocks, and Terraform treats the inline set as COMPLETE — any rule managed as
  # a separate resource is stripped by the next apply that touches this SG. That
  # is exactly how the bastion rule silently vanished before (breaking every dev
  # tunnel/MCP). Keep ALL ingress for this SG inline.
  ingress {
    description     = "Postgres from SSM bastion"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion[0].id]
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

# Subnet group: public subnets when publicly_accessible (needs IGW route),
# else the VPC's intra/private subnets (prod).
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

  # Storage: 20GB gp3, autoscaling to 100GB, encrypted at rest.
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  # Master user — used only for provisioning per-app DBs/roles. App + migrator +
  # viewer roles (least-privilege) are created out-of-band.
  username = "dbadmin"
  password = random_password.rds_master[0].result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  publicly_accessible    = var.rds_publicly_accessible

  # Backups: 7-day automated + PITR. (Supabase free tier has none.)
  backup_retention_period      = 7
  copy_tags_to_snapshot        = true
  performance_insights_enabled = true

  # Staging convenience; tighten for prod (deletion_protection=true, final snapshot).
  apply_immediately         = true
  skip_final_snapshot       = var.rds_skip_final_snapshot
  final_snapshot_identifier = var.rds_skip_final_snapshot ? null : "${local.name_prefix}-db-final"
  deletion_protection       = var.rds_deletion_protection

  auto_minor_version_upgrade = true

  tags = { Name = "${local.name_prefix}-db" }
}

# Store the master connection bits so seeding/ops can fetch them (not the app creds).
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
