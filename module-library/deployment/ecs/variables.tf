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
  description = "VPC for the service and load balancer."
  type        = string
}

variable "subnet_type" {
  description = "Where the tasks run: public (public IP, no NAT needed) or private (no public IP; needs NAT to pull images). The load balancer is always public."
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.subnet_type)
    error_message = "subnet_type must be public or private."
  }
}

variable "public_subnet_ids" {
  description = "Public subnets (load balancer, and tasks when subnet_type = public)."
  type        = list(string)
  default     = []
}

variable "private_subnet_ids" {
  description = "Private subnets (tasks when subnet_type = private)."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Container / task
# ---------------------------------------------------------------------------
variable "container_image" {
  description = "Container image to run, e.g. <account>.dkr.ecr.<region>.amazonaws.com/app:1.0.0."
  type        = string
  default     = "public.ecr.aws/nginx/nginx:stable"
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 80
}

variable "cpu" {
  description = "Task CPU units (256, 512, 1024, 2048, 4096, ...)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task memory in MiB (must be a valid combination with cpu)."
  type        = number
  default     = 512
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64 (must match the image)."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "desired_count" {
  description = "Number of running tasks."
  type        = number
  default     = 1
}

variable "environment_variables" {
  description = "Plain environment variables for the container. Use Secrets Manager/SSM for secrets."
  type        = map(string)
  default     = {}
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights on the cluster (extra cost)."
  type        = bool
  default     = true
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command` into running tasks."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 14
}

# ---------------------------------------------------------------------------
# Load balancer
# ---------------------------------------------------------------------------
variable "enable_load_balancer" {
  description = "Create a public Application Load Balancer in front of the service."
  type        = bool
  default     = true
}

variable "certificate_arn" {
  description = "ACM certificate ARN. When set, the ALB serves HTTPS on 443 and redirects HTTP to HTTPS."
  type        = string
  default     = null
}

variable "alb_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the load balancer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "health_check_path" {
  description = "Target group health check path."
  type        = string
  default     = "/"
}

variable "service_ingress_cidrs" {
  description = "CIDRs allowed to reach the tasks directly when no load balancer is used."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Access to other services in the bundle (wired automatically by the composer)
# ---------------------------------------------------------------------------
variable "s3_bucket_arns" {
  description = "S3 bucket ARNs the task role may read/write."
  type        = list(string)
  default     = []
}

variable "dynamodb_table_arns" {
  description = "DynamoDB table ARNs the task role may read/write."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Add-on: auto scaling
# ---------------------------------------------------------------------------
variable "autoscaling_max_count" {
  description = "Scale the service between desired_count and this many tasks based on CPU. 0 means no auto scaling."
  type        = number
  default     = 0
}

variable "autoscaling_cpu_target" {
  description = "Average CPU percentage auto scaling tries to keep."
  type        = number
  default     = 70
}
