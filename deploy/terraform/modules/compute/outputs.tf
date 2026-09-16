output "public_alb_dns_name" {
  description = "Hostname of the internet facing load balancer."
  value       = aws_lb.public.dns_name
}

output "public_alb_arn_suffix" {
  description = "Suffix CloudWatch uses to identify the internet facing load balancer."
  value       = aws_lb.public.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Suffix CloudWatch uses to identify the application target group."
  value       = aws_lb_target_group.app.arn_suffix
}

output "artifact_bucket" {
  description = "Bucket the instances download the application from at boot."
  value       = aws_s3_bucket.artifacts.id
}

output "autoscaling_group_name" {
  description = "Name of the Auto Scaling group."
  value       = aws_autoscaling_group.app.name
}

output "log_group_name" {
  description = "CloudWatch log group the application writes to."
  value       = aws_cloudwatch_log_group.app.name
}
