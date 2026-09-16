output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = [for subnet in aws_subnet.private : subnet.id]
}

output "data_subnet_ids" {
  description = "Isolated subnet IDs."
  value       = [for subnet in aws_subnet.data : subnet.id]
}

output "data_subnet_arns" {
  description = "Isolated subnet ARNs, the form DataSync expects."
  value       = [for subnet in aws_subnet.data : subnet.arn]
}

output "nat_gateway_id" {
  description = "ID of the NAT gateway."
  value       = aws_nat_gateway.this.id
}
