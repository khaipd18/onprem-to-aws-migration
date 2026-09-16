output "account_id" {
  description = "AWS account the stack is deployed into."
  value       = data.aws_caller_identity.current.account_id
}

output "caller_arn" {
  description = "Identity running Terraform. Expected to be an assumed role."
  value       = data.aws_caller_identity.current.arn
}

output "region" {
  description = "Region the stack is deployed into."
  value       = data.aws_region.current.region
}

output "name_prefix" {
  description = "Prefix applied to every resource name."
  value       = local.name_prefix
}

output "common_tags" {
  description = "Tags applied to every resource through provider default_tags."
  value       = local.common_tags
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = module.network.private_subnet_ids
}

output "data_subnet_ids" {
  description = "Isolated subnet IDs."
  value       = module.network.data_subnet_ids
}

output "nat_gateway_id" {
  description = "ID of the NAT gateway."
  value       = module.network.nat_gateway_id
}

output "security_group_ids" {
  description = "Security group IDs by tier."
  value = {
    alb_public   = module.security.alb_public_id
    app          = module.security.app_id
    rds_proxy    = module.security.rds_proxy_id
    rds          = module.security.rds_id
    fileserver   = module.security.fileserver_id
    admin_client = module.security.admin_client_id
  }
}

output "instance_profile_name" {
  description = "Name of the instance profile."
  value       = module.iam.instance_profile_name
}

output "db_endpoint" {
  description = "Endpoint of the primary database instance."
  value       = module.data.db_endpoint
}

output "db_parameter_prefix" {
  description = "Parameter Store path holding the database connection settings."
  value       = module.data.parameter_prefix
}

output "assets_bucket" {
  description = "Bucket holding the static assets."
  value       = module.static.bucket_name
}

output "assets_uploaded" {
  description = "Number of static assets uploaded."
  value       = module.static.object_count
}

output "cdn_domain_name" {
  description = "Hostname users open, or null when the distribution is not created."
  value       = var.create_cloudfront ? module.cdn[0].domain_name : null
}

output "site_url" {
  description = "Address users open. Serves the single page application and proxies /api/* to the load balancer."
  value       = var.create_cloudfront ? "https://${module.cdn[0].domain_name}" : null
}

output "queue_url" {
  description = "URL of the order queue."
  value       = module.queue.queue_url
}

output "dlq_url" {
  description = "URL of the dead letter queue."
  value       = module.queue.dlq_url
}

output "accept_store_table" {
  description = "DynamoDB table holding accepted order records."
  value       = module.queue.accept_table_name
}

output "public_alb_dns_name" {
  description = "Hostname of the internet facing load balancer."
  value       = module.compute.public_alb_dns_name
}

output "artifact_bucket" {
  description = "Bucket the instances download the application from at boot."
  value       = module.compute.artifact_bucket
}

output "autoscaling_group_name" {
  description = "Name of the Auto Scaling group."
  value       = module.compute.autoscaling_group_name
}

output "alarm_topic_arn" {
  description = "Topic every alarm publishes to."
  value       = module.observability.topic_arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard for the thresholds the brief sets."
  value       = module.observability.dashboard_name
}

output "proxy_endpoint" {
  description = "Endpoint of the database proxy, or null when it is not created."
  value       = module.data.proxy_endpoint
}

output "efs_id" {
  description = "ID of the shared file system."
  value       = module.fileserver.file_system_id
}

output "efs_access_points" {
  description = "Access point IDs by department."
  value       = module.fileserver.access_point_ids
}

output "migration_start_commands" {
  description = "Commands that begin the migration, or null when the migration tooling is not created."
  value       = var.create_migration ? module.migration[0].start_commands : null
}
