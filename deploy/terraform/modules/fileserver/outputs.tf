output "file_system_id" {
  description = "ID of the file system."
  value       = aws_efs_file_system.main.id
}

output "file_system_arn" {
  description = "ARN of the file system."
  value       = aws_efs_file_system.main.arn
}

output "dns_name" {
  description = "Hostname instances mount."
  value       = aws_efs_file_system.main.dns_name
}

output "access_point_arns" {
  description = "Access point ARNs by department, plus the shared one."
  value = merge(
    { for name, ap in aws_efs_access_point.department : name => ap.arn },
    { public = aws_efs_access_point.shared.arn },
  )
}

output "access_point_ids" {
  description = "Access point IDs by department, for the mount command."
  value = merge(
    { for name, ap in aws_efs_access_point.department : name => ap.id },
    { public = aws_efs_access_point.shared.id },
  )
}

output "mount_command_example" {
  description = "How a department mounts its own folder. The access point decides the identity, so the command carries no user or password."
  value       = "sudo mount -t efs -o tls,iam,accesspoint=<access point id> ${aws_efs_file_system.main.id}:/ /mnt/<phong ban>"
}
