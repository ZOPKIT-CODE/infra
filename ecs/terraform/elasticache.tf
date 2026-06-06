# elasticache.tf — Valkey (Redis-compatible) ElastiCache replication group.
#
# Cluster-mode DISABLED single shard. Backs the suite's permission/auth caches
# (REDIS_ENABLED + fleet-wide invalidation on channel authz:invalidate). The
# generated REDIS_URL/credentials land in Secrets Manager for the apps to read.

# ---------------------------------------------------------------------------
# Auth token (Valkey AUTH). 48 chars, no special chars to keep the URL clean.
# ---------------------------------------------------------------------------
resource "random_password" "valkey" {
  length  = 48
  special = false
}

# ---------------------------------------------------------------------------
# Security group: allow 6379 from the ECS task security group (the Fargate
# task ENIs). Egress open.
# ---------------------------------------------------------------------------
resource "aws_security_group" "valkey" {
  name        = "${local.name_prefix}-valkey"
  description = "Valkey ElastiCache access from ECS Fargate tasks"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Valkey from ECS task security group"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-valkey"
  }
}

# ---------------------------------------------------------------------------
# Subnet group on the VPC intra (private, no NAT) subnets.
# ---------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "valkey" {
  name       = "${local.name_prefix}-valkey"
  subnet_ids = module.vpc.intra_subnets

  tags = {
    Name = "${local.name_prefix}-valkey"
  }
}

# ---------------------------------------------------------------------------
# Replication group (cluster-mode disabled). One primary + var.valkey_replicas
# read replicas. Failover/Multi-AZ only make sense when replicas exist.
# Encryption in transit (TLS) + at rest, AUTH token enabled.
# ---------------------------------------------------------------------------
resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "${local.name_prefix}-valkey"
  description          = "Zopkit suite Valkey cache (cluster-mode disabled)"

  engine         = "valkey"
  engine_version = "7.2"
  node_type      = var.valkey_node_type
  port           = 6379

  # 1 primary + N replicas.
  num_cache_clusters = 1 + var.valkey_replicas

  # Failover / Multi-AZ require at least one replica.
  automatic_failover_enabled = var.valkey_replicas > 0
  multi_az_enabled           = var.valkey_replicas > 0

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  auth_token                 = random_password.valkey.result

  security_group_ids = [aws_security_group.valkey.id]
  subnet_group_name  = aws_elasticache_subnet_group.valkey.name

  tags = {
    Name = "${local.name_prefix}-valkey"
  }
}

# ---------------------------------------------------------------------------
# Secrets Manager: connection details for the apps (injected into ECS tasks via
# the task def 'secrets' block). REDIS_URL uses the rediss:// (TLS) scheme +
# AUTH token + primary endpoint.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "valkey" {
  name        = "${var.project}/${var.environment}/valkey"
  description = "Valkey connection URL + auth token for the Zopkit suite"

  tags = {
    Name = "${local.name_prefix}-valkey"
  }
}

resource "aws_secretsmanager_secret_version" "valkey" {
  secret_id = aws_secretsmanager_secret.valkey.id
  secret_string = jsonencode({
    REDIS_ENABLED  = "true"
    REDIS_URL      = "rediss://:${random_password.valkey.result}@${aws_elasticache_replication_group.valkey.primary_endpoint_address}:6379"
    REDIS_PASSWORD = random_password.valkey.result
    REDIS_TLS      = "true"
  })
}
