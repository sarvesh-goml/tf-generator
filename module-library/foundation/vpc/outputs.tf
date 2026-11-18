output "mode" {
  description = "Network mode in use: new, default, or existing."
  value       = local.mode
}

output "vpc_id" {
  description = "ID of the VPC in use."
  value       = var.create_vpc ? one(aws_vpc.this[*].id) : one(data.aws_vpc.selected[*].id)
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = var.create_vpc ? one(aws_vpc.this[*].cidr_block) : one(data.aws_vpc.selected[*].cidr_block)
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value = (
    local.mode == "new" ? aws_subnet.public[*].id :
    local.mode == "default" ? sort(one(data.aws_subnets.default[*].ids)) :
    var.existing_public_subnet_ids
  )

  precondition {
    condition     = local.mode != "existing" || length(var.existing_public_subnet_ids) + length(var.existing_private_subnet_ids) > 0
    error_message = "When using an existing VPC, set existing_public_subnet_ids and/or existing_private_subnet_ids."
  }
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (empty for the default VPC, which has none)."
  value = (
    local.mode == "new" ? aws_subnet.private[*].id :
    local.mode == "default" ? [] :
    var.existing_private_subnet_ids
  )
}

output "nat_gateway_ids" {
  description = "IDs of the NAT gateways (only when a new VPC is created with NAT enabled)."
  value       = aws_nat_gateway.this[*].id
}
