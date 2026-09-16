output "db_instance_identifier" {
  description = "Identifier of the primary database instance."
  value       = aws_db_instance.main.identifier
}

output "db_endpoint" {
  description = "Endpoint of the primary database instance."
  value       = aws_db_instance.main.endpoint
}

output "db_address" {
  description = "Hostname of the primary database instance."
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "Port the database listens on."
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Name of the initial database."
  value       = aws_db_instance.main.db_name
}

output "parameter_prefix" {
  description = "Parameter Store path holding the connection settings."
  value       = "/${var.name_prefix}/db"
}

output "password_parameter_name" {
  description = "Parameter holding the master password as a SecureString."
  value       = aws_ssm_parameter.db_password.name
}

output "proxy_endpoint" {
  description = "Endpoint of the database proxy, or null when the proxy is not created."
  value       = var.create_proxy ? aws_db_proxy.main[0].endpoint : null
}
