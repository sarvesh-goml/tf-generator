variable "name_prefix" {
  description = "Prefix used for naming every resource in this module."
  type        = string
}

variable "tags" {
  description = "Extra tags to add to resources (provider default_tags are applied on top)."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Network mode
#   create_vpc = true                               -> build a new VPC (public + private subnets)
#   create_vpc = false, existing_vpc_id = null      -> use the account's default VPC (public subnets only)
#   create_vpc = false, existing_vpc_id = "vpc-..." -> use an existing VPC and the subnet IDs you give
# ---------------------------------------------------------------------------
variable "create_vpc" {
  description = "Create a new dedicated VPC. False uses the default VPC, or existing_vpc_id when set."
  type        = bool
  default     = false
}

variable "existing_vpc_id" {
  description = "ID of an existing VPC to use when create_vpc = false. Null means the account's default VPC."
  type        = string
  default     = null
}

variable "existing_public_subnet_ids" {
  description = "Public subnet IDs of the existing VPC. Used when create_vpc = false."
  type        = list(string)
  default     = []
}

variable "existing_private_subnet_ids" {
  description = "Private subnet IDs of the existing VPC. Used when create_vpc = false."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# New VPC settings
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the new VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, e.g. 10.0.0.0/16."
  }
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 6
    error_message = "az_count must be between 1 and 6."
  }
}

variable "subnet_newbits" {
  description = "Bits added to the VPC prefix for each subnet (8 on a /16 gives /24 subnets)."
  type        = number
  default     = 8
}

variable "enable_nat_gateway" {
  description = "Create NAT gateway(s) so private subnets can reach the internet (needed by ECS Fargate in private subnets to pull images). NAT gateways cost money per hour."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway (cheaper) instead of one per AZ (highly available)."
  type        = bool
  default     = true
}
