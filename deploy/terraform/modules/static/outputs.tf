output "bucket_name" {
  description = "Name of the asset bucket."
  value       = aws_s3_bucket.assets.id
}

output "bucket_arn" {
  description = "ARN of the asset bucket."
  value       = aws_s3_bucket.assets.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name, used as the distribution origin."
  value       = aws_s3_bucket.assets.bucket_regional_domain_name
}

output "object_count" {
  description = "Number of objects uploaded from the local directory."
  value       = length(aws_s3_object.assets)
}
