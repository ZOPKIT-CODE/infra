resource "random_password" "valkey" {
  count   = var.enable_valkey ? 1 : 0
  length  = 48
  special = false
}

resource "aws_security_group" "valkey" {
  count       = var.enable_valkey ? 1 : 0
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

resource "aws_elasticache_subnet_group" "valkey" {
  count      = var.enable_valkey ? 1 : 0
  name       = "${local.name_prefix}-valkey"
  subnet_ids = module.vpc.intra_subnets

  tags = {
    Name = "${local.name_prefix}-valkey"
  }
}

resource "aws_elasticache_replication_group" "valkey" {
  count                = var.enable_valkey ? 1 : 0
  replication_group_id = "${local.name_prefix}-valkey"
  description          = "Zopkit suite Valkey cache (cluster-mode disabled)"

  engine         = "valkey"
  engine_version = "7.2"
  node_type      = var.valkey_node_type
  port           = 6379

  apply_immediately = true

  num_cache_clusters = 1 + var.valkey_replicas

  automatic_failover_enabled = var.valkey_replicas > 0
  multi_az_enabled           = var.valkey_replicas > 0

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  auth_token                 = random_password.valkey[0].result

  security_group_ids = [aws_security_group.valkey[0].id]
  subnet_group_name  = aws_elasticache_subnet_group.valkey[0].name

  tags = {
    Name = "${local.name_prefix}-valkey"
  }
}

resource "aws_secretsmanager_secret" "valkey" {
  count       = var.enable_valkey ? 1 : 0
  name        = "${var.project}/${var.environment}/valkey"
  description = "Valkey connection URL + auth token for the Zopkit suite"

  tags = {
    Name = "${local.name_prefix}-valkey"
  }
}

resource "aws_secretsmanager_secret_version" "valkey" {
  count     = var.enable_valkey ? 1 : 0
  secret_id = aws_secretsmanager_secret.valkey[0].id
  secret_string = jsonencode({
    REDIS_ENABLED  = "true"
    REDIS_URL      = "rediss://:${random_password.valkey[0].result}@${aws_elasticache_replication_group.valkey[0].primary_endpoint_address}:6379"
    REDIS_PASSWORD = random_password.valkey[0].result
    REDIS_TLS      = "true"
  })
}
