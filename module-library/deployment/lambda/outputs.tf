output "function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "Lambda function ARN."
  value       = aws_lambda_function.this.arn
}

output "invoke_arn" {
  description = "Invoke ARN, used when wiring API Gateway."
  value       = aws_lambda_function.this.invoke_arn
}

output "role_name" {
  description = "Execution role name (attach extra policies here)."
  value       = aws_iam_role.this.name
}

output "role_arn" {
  description = "Execution role ARN."
  value       = aws_iam_role.this.arn
}

output "log_group_name" {
  description = "CloudWatch log group name."
  value       = aws_cloudwatch_log_group.this.name
}

output "function_url" {
  description = "HTTPS endpoint of the function (null unless enable_function_url = true)."
  value       = one(aws_lambda_function_url.this[*].function_url)
}
