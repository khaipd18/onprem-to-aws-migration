output "replication_instance_arn" {
  description = "ARN of the replication instance."
  value       = aws_dms_replication_instance.main.replication_instance_arn
}

output "replication_task_arn" {
  description = "ARN of the replication task. It is created stopped; start it when the cutover window opens."
  value       = aws_dms_replication_task.main.replication_task_arn
}

output "datasync_task_arn" {
  description = "ARN of the file copy task, or null when the file part is disabled."
  value       = one(aws_datasync_task.files[*].arn)
}

output "start_commands" {
  description = "Commands that begin the migration once the task exists."
  value = {
    database = "aws dms start-replication-task --replication-task-arn ${aws_dms_replication_task.main.replication_task_arn} --start-replication-task-type start-replication"
    files    = try("aws datasync start-task-execution --task-arn ${aws_datasync_task.files[0].arn}", "phần file chưa bật")
    validate = "aws dms describe-table-statistics --replication-task-arn ${aws_dms_replication_task.main.replication_task_arn} --query 'TableStatistics[].[TableName,ValidationState,ValidationFailedRecords]' --output table"
  }
}
