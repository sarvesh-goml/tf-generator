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
# Function
# ---------------------------------------------------------------------------
variable "function_name" {
  description = "Function name. Defaults to <name_prefix>-fn."
  type        = string
  default     = null
}

variable "source_dir" {
  description = "Directory with the function code, zipped automatically. Null uses the bundled sample in ./src."
  type        = string
  default     = null
}

variable "runtime" {
  description = "Lambda runtime."
  type        = string
  default     = "python3.12"
}

variable "handler" {
  description = "Function entrypoint (file.function)."
  type        = string
  default     = "handler.lambda_handler"
}

variable "architecture" {
  description = "x86_64 or arm64 (arm64 is cheaper for most workloads)."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64."
  }
}

variable "memory_size" {
  description = "Memory in MB (128-10240)."
  type        = number
  default     = 128

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size must be between 128 and 10240."
  }
}

variable "timeout" {
  description = "Timeout in seconds (1-900)."
  type        = number
  default     = 10

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "timeout must be between 1 and 900."
  }
}

variable "environment_variables" {
  description = "Environment variables for the function."
  type        = map(string)
  default     = {}
}

variable "reserved_concurrent_executions" {
  description = "Reserved concurrency. -1 means unreserved."
  type        = number
  default     = -1
}

variable "tracing_mode" {
  description = "X-Ray tracing mode: PassThrough or Active."
  type        = string
  default     = "PassThrough"

  validation {
    condition     = contains(["PassThrough", "Active"], var.tracing_mode)
    error_message = "tracing_mode must be PassThrough or Active."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 14
}

# ---------------------------------------------------------------------------
# Optional VPC attachment
# ---------------------------------------------------------------------------
variable "attach_to_vpc" {
  description = "Run the function inside a VPC (needed to reach private resources such as RDS)."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "VPC ID (required when attach_to_vpc = true)."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Private subnet IDs (required when attach_to_vpc = true)."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Access to other services in the bundle (wired automatically by the composer)
# ---------------------------------------------------------------------------
variable "s3_bucket_arns" {
  description = "S3 bucket ARNs the function may read/write."
  type        = list(string)
  default     = []
}

variable "dynamodb_table_arns" {
  description = "DynamoDB table ARNs the function may read/write."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Add-ons
# ---------------------------------------------------------------------------
variable "enable_function_url" {
  description = "Give the function its own HTTPS endpoint (https://<id>.lambda-url.<region>.on.aws/)."
  type        = bool
  default     = false
}

variable "function_url_auth_type" {
  description = "NONE = anyone with the URL can call it. AWS_IAM = callers must sign requests with AWS credentials."
  type        = string
  default     = "NONE"

  validation {
    condition     = contains(["NONE", "AWS_IAM"], var.function_url_auth_type)
    error_message = "function_url_auth_type must be NONE or AWS_IAM."
  }
}

variable "schedule_expression" {
  description = "Run the function on a schedule, e.g. rate(1 hour), rate(5 minutes) or cron(0 9 * * ? *). Null means no schedule."
  type        = string
  default     = null

  validation {
    condition     = var.schedule_expression == null || can(regex("^(rate|cron)\\(.+\\)$", var.schedule_expression))
    error_message = "schedule_expression must look like rate(1 hour) or cron(0 9 * * ? *)."
  }
}
