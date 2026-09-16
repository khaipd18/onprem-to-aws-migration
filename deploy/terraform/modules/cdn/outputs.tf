output "distribution_id" {
  description = "ID of the distribution."
  value       = aws_cloudfront_distribution.main.id
}

output "distribution_arn" {
  description = "ARN of the distribution, referenced by the asset bucket policy."
  value       = aws_cloudfront_distribution.main.arn
}

output "domain_name" {
  description = "Hostname users open. Served over HTTPS with the certificate AWS provides for this domain."
  value       = aws_cloudfront_distribution.main.domain_name
}

output "static_base_url" {
  description = "Value for the STATIC_BASE_URL environment variable of the web tier."
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}
