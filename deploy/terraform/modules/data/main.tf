resource "aws_db_subnet_group" "main" {
  name        = "${var.name_prefix}-db"
  description = "Isolated subnets for the ${var.name_prefix} database"
  subnet_ids  = var.subnet_ids

  tags = { Name = "${var.name_prefix}-db" }
}

resource "aws_db_parameter_group" "main" {
  name        = "${var.name_prefix}-pg16"
  description = "PostgreSQL settings for ${var.name_prefix}"
  family      = "postgres16"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_min_duration_statement"
    value        = "500"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_lock_waits"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "idle_in_transaction_session_timeout"
    value        = "60000"
    apply_method = "immediate"
  }

  tags = { Name = "${var.name_prefix}-pg16" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "random_password" "master" {
  length           = 32
  special          = true
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_instance" "main" {
  identifier     = "${var.name_prefix}-db"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.database_name
  username = var.master_username
  password = random_password.master.result
  port     = 5432

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = var.security_group_ids
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.main.name

  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_encrypted     = true

  backup_retention_period   = var.backup_retention_days
  backup_window             = var.backup_window
  maintenance_window        = var.maintenance_window
  copy_tags_to_snapshot     = true
  delete_automated_backups  = false
  skip_final_snapshot       = var.allow_destroy
  final_snapshot_identifier = var.allow_destroy ? null : "${var.name_prefix}-db-final"

  auto_minor_version_upgrade = false
  deletion_protection        = !var.allow_destroy
  apply_immediately          = false

  performance_insights_enabled = true

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = { Name = "${var.name_prefix}-db" }
}

resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.name_prefix}/db/host"
  type  = "String"
  value = var.create_proxy ? aws_db_proxy.main[0].endpoint : aws_db_instance.main.address

  tags = { Name = "${var.name_prefix}-db-host" }
}

resource "aws_ssm_parameter" "db_port" {
  name  = "/${var.name_prefix}/db/port"
  type  = "String"
  value = tostring(aws_db_instance.main.port)

  tags = { Name = "${var.name_prefix}-db-port" }
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.name_prefix}/db/name"
  type  = "String"
  value = var.database_name

  tags = { Name = "${var.name_prefix}-db-name" }
}

resource "aws_ssm_parameter" "db_user" {
  name  = "/${var.name_prefix}/db/user"
  type  = "String"
  value = var.master_username

  tags = { Name = "${var.name_prefix}-db-user" }
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.name_prefix}/db/password"
  type  = "SecureString"
  value = random_password.master.result

  tags = { Name = "${var.name_prefix}-db-password" }
}

resource "aws_secretsmanager_secret" "master" {
  count = var.create_proxy ? 1 : 0

  name        = "${var.name_prefix}/db/master"
  description = "Master credentials the proxy authenticates with"

  tags = { Name = "${var.name_prefix}-db-master" }
}

resource "aws_secretsmanager_secret_version" "master" {
  count = var.create_proxy ? 1 : 0

  secret_id = aws_secretsmanager_secret.master[0].id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
  })
}

resource "aws_db_proxy" "main" {
  count = var.create_proxy ? 1 : 0

  name                   = "${var.name_prefix}-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = var.proxy_role_arn
  vpc_subnet_ids         = var.subnet_ids
  vpc_security_group_ids = var.proxy_security_group_ids
  require_tls            = true
  idle_client_timeout    = 1800

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.master[0].arn
  }

  tags = { Name = "${var.name_prefix}-proxy" }
}

resource "aws_db_proxy_default_target_group" "main" {
  count = var.create_proxy ? 1 : 0

  db_proxy_name = aws_db_proxy.main[0].name

  connection_pool_config {
    max_connections_percent      = 90
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 120
  }
}

resource "aws_db_proxy_target" "main" {
  count = var.create_proxy ? 1 : 0

  db_proxy_name          = aws_db_proxy.main[0].name
  target_group_name      = aws_db_proxy_default_target_group.main[0].name
  db_instance_identifier = aws_db_instance.main.identifier
}
