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
# Networking
# ---------------------------------------------------------------------------
variable "vpc_id" {
  description = "VPC to launch the instance in."
  type        = string
}

variable "subnet_type" {
  description = "Where to launch the instance: public (gets a public IP) or private (no public IP; needs NAT for internet)."
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.subnet_type)
    error_message = "subnet_type must be public or private."
  }
}

variable "public_subnet_ids" {
  description = "Public subnets to choose from."
  type        = list(string)
  default     = []
}

variable "private_subnet_ids" {
  description = "Private subnets to choose from."
  type        = list(string)
  default     = []
}

variable "subnet_index" {
  description = "Which of the candidate subnets to use (wraps around), so several instances spread across subnets and AZs."
  type        = number
  default     = 0
}

variable "subnet_id" {
  description = "Pin the instance to this exact subnet ID (overrides the automatic choice)."
  type        = string
  default     = null
}

variable "ingress_rules" {
  description = "Inbound rules for the instance security group. Empty by default: use SSM Session Manager instead of opening SSH."
  type = list(object({
    description = string
    from_port   = number
    to_port     = number
    ip_protocol = string
    cidr_ipv4   = string
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "AMI ID. Leave null to use the latest Amazon Linux 2023 AMI for the chosen architecture."
  type        = string
  default     = null
}

variable "architecture" {
  description = "CPU architecture used for the default AMI lookup: x86_64 or arm64 (must match instance_type)."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64."
  }
}

variable "key_name" {
  description = "Optional EC2 key pair name for SSH. Prefer SSM Session Manager."
  type        = string
  default     = null
}

variable "user_data" {
  description = "Optional user data script run at first boot."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 20
}

variable "root_volume_type" {
  description = "Root EBS volume type."
  type        = string
  default     = "gp3"
}

variable "detailed_monitoring" {
  description = "Enable 1-minute CloudWatch detailed monitoring (extra cost)."
  type        = bool
  default     = false
}

variable "enable_ssm" {
  description = "Attach the SSM managed policy so the instance is reachable through Session Manager."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Access to other services in the bundle (wired automatically by the composer)
# ---------------------------------------------------------------------------
variable "s3_bucket_arns" {
  description = "S3 bucket ARNs the instance role may read/write."
  type        = list(string)
  default     = []
}

variable "dynamodb_table_arns" {
  description = "DynamoDB table ARNs the instance role may read/write."
  type        = list(string)
  default     = []
}

variable "ecr_repository_arns" {
  description = "ECR repository ARNs the instance role may pull from."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Add-ons
# ---------------------------------------------------------------------------
variable "create_elastic_ip" {
  description = "Attach an Elastic IP: a static public IP that stays the same across stop/start. Needs a public subnet."
  type        = bool
  default     = false
}

variable "data_volume_size" {
  description = "Size in GiB of an extra encrypted gp3 data disk attached as /dev/sdf. 0 means no extra disk."
  type        = number
  default     = 0

  validation {
    condition     = var.data_volume_size == 0 || (var.data_volume_size >= 1 && var.data_volume_size <= 16384)
    error_message = "data_volume_size must be 0 (no disk) or between 1 and 16384 GiB."
  }
}
