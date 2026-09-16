output "alb_public_id" {
  description = "Security group of the public load balancer."
  value       = aws_security_group.alb_public.id
}

output "app_id" {
  description = "Security group of the application tier instances and workers."
  value       = aws_security_group.app.id
}

output "rds_proxy_id" {
  description = "Security group of the database proxy."
  value       = aws_security_group.rds_proxy.id
}

output "rds_id" {
  description = "Security group of the database instances."
  value       = aws_security_group.rds.id
}

output "fileserver_id" {
  description = "Security group of the file server."
  value       = aws_security_group.fileserver.id
}

output "admin_client_id" {
  description = "Security group of the administrative workstation and DataSync agent."
  value       = aws_security_group.admin_client.id
}

output "app_arn" {
  description = "ARN of the application tier security group, the form DataSync expects."
  value       = aws_security_group.app.arn
}
