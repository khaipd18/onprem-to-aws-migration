resource "aws_dms_replication_subnet_group" "main" {
  replication_subnet_group_id          = "${var.name_prefix}-dms"
  replication_subnet_group_description = "Subnets the ${var.name_prefix} replication instance runs in"
  subnet_ids                           = var.subnet_ids

  tags = { Name = "${var.name_prefix}-dms" }
}

resource "aws_dms_replication_instance" "main" {
  replication_instance_id    = "${var.name_prefix}-dms"
  replication_instance_class = var.instance_class
  allocated_storage          = var.allocated_storage
  multi_az                   = var.multi_az

  replication_subnet_group_id  = aws_dms_replication_subnet_group.main.id
  vpc_security_group_ids       = var.security_group_ids
  publicly_accessible          = false
  auto_minor_version_upgrade   = false
  apply_immediately            = true
  preferred_maintenance_window = "sun:20:00-sun:21:00"

  tags = { Name = "${var.name_prefix}-dms" }
}

resource "aws_dms_endpoint" "source" {
  endpoint_id   = "${var.name_prefix}-source"
  endpoint_type = "source"
  engine_name   = "postgres"

  server_name   = var.source_db.host
  port          = var.source_db.port
  database_name = var.source_db.database
  username      = var.source_db.username
  password      = var.source_db.password
  ssl_mode      = "require"

  tags = { Name = "${var.name_prefix}-source" }
}

resource "aws_dms_endpoint" "target" {
  endpoint_id   = "${var.name_prefix}-target"
  endpoint_type = "target"
  engine_name   = "postgres"

  server_name   = var.target_db.host
  port          = var.target_db.port
  database_name = var.target_db.database
  username      = var.target_db.username
  password      = var.target_db.password
  ssl_mode      = "require"

  tags = { Name = "${var.name_prefix}-target" }
}

locals {
  table_mappings = jsonencode({
    rules = [
      for i, t in var.migrated_tables : {
        "rule-type"      = "selection"
        "rule-id"        = tostring(i + 1)
        "rule-name"      = t
        "object-locator" = { "schema-name" = "public", "table-name" = t }
        "rule-action"    = "include"
      }
    ]
  })

  task_settings = jsonencode({
    TargetMetadata = {
      LoadMaxFileSize   = 32768
      BatchApplyEnabled = true
    }

    FullLoadSettings = {
      TargetTablePrepMode            = "DO_NOTHING"
      CommitRate                     = 10000
      StopTaskCachedChangesetApplied = false
    }

    ValidationSettings = {
      EnableValidation            = true
      ValidationMode              = "ROW_LEVEL"
      ThreadCount                 = 5
      PartitionSize               = 10000
      FailureMaxCount             = 10000
      RecordFailureDelayInMinutes = 5
      RecordSuspendDelayInMinutes = 30
      ValidationOnly              = false
      HandleCollationDiff         = false
      TableFailureMaxCount        = 1000
      ValidationPartialLobSize    = 0
      SkipLobColumns              = false
    }

    Logging = {
      EnableLogging = true
      LogComponents = [
        { Id = "SOURCE_UNLOAD", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_LOAD", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "SOURCE_CAPTURE", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_APPLY", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "VALIDATOR", Severity = "LOGGER_SEVERITY_DETAILED_DEBUG" },
      ]
    }

    ErrorBehavior = {
      ApplyErrorPolicy                     = "STOP_TASK"
      ApplyErrorInsertPolicy               = "LOG_ERROR"
      ApplyErrorUpdatePolicy               = "LOG_ERROR"
      ApplyErrorDeletePolicy               = "LOG_ERROR"
      DataErrorPolicy                      = "LOG_ERROR"
      TableErrorPolicy                     = "SUSPEND_TABLE"
      FailOnNoTablesCaptured               = true
      FailOnTransactionConsistencyBreached = true
    }
  })
}

resource "aws_dms_replication_task" "main" {
  replication_task_id      = "${var.name_prefix}-task"
  migration_type           = "full-load-and-cdc"
  replication_instance_arn = aws_dms_replication_instance.main.replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source.endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.target.endpoint_arn

  table_mappings            = local.table_mappings
  replication_task_settings = local.task_settings

  start_replication_task = false

  tags = { Name = "${var.name_prefix}-task" }

  lifecycle {
    ignore_changes = [replication_task_settings]
  }
}

resource "aws_datasync_location_s3" "source" {
  count = var.enable_file_migration ? 1 : 0

  s3_bucket_arn = var.source_files_bucket_arn
  subdirectory  = "/fileshare"

  s3_config {
    bucket_access_role_arn = var.datasync_role_arn
  }

  tags = { Name = "${var.name_prefix}-files-source" }
}

resource "aws_datasync_location_efs" "target" {
  count = var.enable_file_migration ? 1 : 0

  efs_file_system_arn = var.target_efs_arn
  subdirectory        = "/"

  ec2_config {
    subnet_arn          = var.subnet_arns[0]
    security_group_arns = var.security_group_arns
  }

  tags = { Name = "${var.name_prefix}-files-target" }
}

resource "aws_cloudwatch_log_group" "datasync" {
  count = var.enable_file_migration ? 1 : 0

  name              = "/${var.name_prefix}/datasync"
  retention_in_days = var.log_retention_days

  tags = { Name = "${var.name_prefix}-datasync" }
}

resource "aws_datasync_task" "files" {
  count = var.enable_file_migration ? 1 : 0

  name                     = "${var.name_prefix}-files"
  source_location_arn      = aws_datasync_location_s3.source[0].arn
  destination_location_arn = aws_datasync_location_efs.target[0].arn
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.datasync[0].arn

  options {
    posix_permissions = "PRESERVE"
    uid               = "INT_VALUE"
    gid               = "INT_VALUE"

    preserve_deleted_files = "PRESERVE"
    overwrite_mode         = "ALWAYS"
    verify_mode            = "ONLY_FILES_TRANSFERRED"
    log_level              = "TRANSFER"
    task_queueing          = "ENABLED"
  }

  tags = { Name = "${var.name_prefix}-files" }
}
