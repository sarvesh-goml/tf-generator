output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Private IP address."
  value       = aws_instance.this.private_ip
}

output "public_ip" {
  description = "Public IP address (only when subnet_type = public)."
  value       = aws_instance.this.public_ip
}

output "security_group_id" {
  description = "ID of the instance security group."
  value       = aws_security_group.this.id
}

output "iam_role_name" {
  description = "Name of the instance IAM role (attach extra policies here)."
  value       = aws_iam_role.this.name
}

output "iam_role_arn" {
  description = "ARN of the instance IAM role."
  value       = aws_iam_role.this.arn
}

output "subnet_id" {
  description = "Subnet the instance runs in."
  value       = aws_instance.this.subnet_id
}

output "elastic_ip" {
  description = "Elastic IP address (null unless create_elastic_ip = true)."
  value       = one(aws_eip.this[*].public_ip)
}

output "data_volume_id" {
  description = "ID of the extra data disk (null if none)."
  value       = one(aws_ebs_volume.data[*].id)
}
