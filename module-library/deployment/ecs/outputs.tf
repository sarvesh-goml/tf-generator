output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "Task definition ARN."
  value       = aws_ecs_task_definition.this.arn
}

output "task_role_arn" {
  description = "Task role ARN (attach extra application permissions here)."
  value       = aws_iam_role.task.arn
}

output "service_security_group_id" {
  description = "Security group ID of the tasks."
  value       = aws_security_group.service.id
}

output "alb_dns_name" {
  description = "Load balancer DNS name (null if disabled)."
  value       = one(aws_lb.this[*].dns_name)
}

output "service_url" {
  description = "URL of the service through the load balancer (null if disabled)."
  value       = var.enable_load_balancer ? "${local.https_enabled ? "https" : "http"}://${one(aws_lb.this[*].dns_name)}" : null
}

output "log_group_name" {
  description = "CloudWatch log group for container logs."
  value       = aws_cloudwatch_log_group.this.name
}
