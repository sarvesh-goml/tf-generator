output "repository_name" {
  description = "Repository name."
  value       = aws_ecr_repository.this.name
}

output "repository_url" {
  description = "Repository URL to tag and push images to."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "Repository ARN."
  value       = aws_ecr_repository.this.arn
}

output "registry_id" {
  description = "Registry (AWS account) ID."
  value       = aws_ecr_repository.this.registry_id
}
