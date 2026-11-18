output "table_name" {
  description = "Table name."
  value       = aws_dynamodb_table.this.name
}

output "table_arn" {
  description = "Table ARN."
  value       = aws_dynamodb_table.this.arn
}

output "stream_arn" {
  description = "Stream ARN (null when streams are disabled)."
  value       = aws_dynamodb_table.this.stream_arn
}
