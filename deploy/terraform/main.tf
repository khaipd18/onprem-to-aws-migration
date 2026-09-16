module "network" {
  source = "./modules/network"

  name_prefix     = local.name_prefix
  region          = var.aws_region
  vpc_cidr        = var.vpc_cidr
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets
  data_subnets    = var.data_subnets
}

module "security" {
  source = "./modules/security"

  name_prefix = local.name_prefix
  vpc_id      = module.network.vpc_id
}

module "iam" {
  source = "./modules/iam"

  name_prefix = local.name_prefix
}

module "data" {
  source = "./modules/data"

  name_prefix        = local.name_prefix
  subnet_ids         = module.network.data_subnet_ids
  security_group_ids = [module.security.rds_id]

  create_proxy             = var.create_rds_proxy
  proxy_security_group_ids = [module.security.rds_proxy_id]
  proxy_role_arn           = module.iam.proxy_role_arn
  allow_destroy            = var.allow_destroy
}

module "static" {
  source = "./modules/static"

  name_prefix   = local.name_prefix
  assets_dir    = var.assets_dir
  allow_destroy = var.allow_destroy
}

module "cdn" {
  source = "./modules/cdn"
  count  = var.create_cloudfront ? 1 : 0

  name_prefix                        = local.name_prefix
  alb_domain_name                    = var.alb_domain_name
  assets_bucket_id                   = module.static.bucket_name
  assets_bucket_arn                  = module.static.bucket_arn
  assets_bucket_regional_domain_name = module.static.bucket_regional_domain_name
}

module "queue" {
  source = "./modules/queue"

  name_prefix = local.name_prefix

  visibility_timeout_seconds = var.queue_visibility_timeout_seconds
  max_receive_count          = var.queue_max_receive_count
  allow_destroy              = var.allow_destroy
}

module "compute" {
  source = "./modules/compute"

  name_prefix        = local.name_prefix
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids

  alb_security_group_id = module.security.alb_public_id
  app_security_group_id = module.security.app_id
  instance_profile_name = module.iam.instance_profile_name

  instance_type  = var.instance_type
  warm_pool_size = var.warm_pool_size

  queue_url = module.queue.queue_url
  dlq_url   = module.queue.dlq_url

  visibility_timeout_seconds = var.queue_visibility_timeout_seconds
  max_receive_count          = var.queue_max_receive_count

  accept_store_driver = var.accept_store_driver
  accept_store_name   = module.queue.accept_table_name

  allowed_origins = var.create_cloudfront ? "https://${module.cdn[0].domain_name}" : "*"
  propagated_tags = local.common_tags
  allow_destroy   = var.allow_destroy
}

module "observability" {
  source = "./modules/observability"

  name_prefix = local.name_prefix
  alarm_email = var.alarm_email

  public_alb_arn_suffix   = module.compute.public_alb_arn_suffix
  target_group_arn_suffix = module.compute.target_group_arn_suffix
  log_group_name          = module.compute.log_group_name

  db_instance_identifier = module.data.db_instance_identifier
  queue_name             = module.queue.queue_name
  dlq_name               = module.queue.dlq_name
}

module "fileserver" {
  source = "./modules/fileserver"

  name_prefix        = local.name_prefix
  subnet_ids         = module.network.data_subnet_ids
  security_group_ids = [module.security.fileserver_id]
}

module "migration" {
  source = "./modules/migration"
  count  = var.create_migration ? 1 : 0

  name_prefix        = local.name_prefix
  subnet_ids         = module.network.data_subnet_ids
  security_group_ids = [module.security.app_id]

  create_service_roles = var.create_dms_service_roles

  source_db = var.migration_source_db
  target_db = {
    host     = module.data.db_address
    port     = module.data.db_port
    database = module.data.db_name
    username = var.db_master_username
    password = ""
  }

  enable_file_migration   = var.migration_files_bucket_arn != ""
  source_files_bucket_arn = var.migration_files_bucket_arn
  target_efs_arn          = module.fileserver.file_system_arn
  datasync_role_arn       = var.datasync_role_arn
  security_group_arns     = [module.security.app_arn]
  subnet_arns             = module.network.data_subnet_arns
}
