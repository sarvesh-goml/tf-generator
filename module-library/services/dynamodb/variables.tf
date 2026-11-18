variable "name_prefix" {
  description = "Prefix used for naming every resource in this module."
  type        = string
}

variable "tags" {
  description = "Extra tags to add to resources (provider default_tags are applied on top)."
  type        = map(string)
  default     = {}
}

variable "table_name" {
  description = "Table name. Defaults to <name_prefix>-table."
  type        = string
  default     = null
}

variable "hash_key" {
  description = "Partition key attribute name."
  type        = string
  default     = "id"
}

variable "hash_key_type" {
  description = "Partition key type: S (string), N (number), or B (binary)."
  type        = string
  default     = "S"

  validation {
    condition     = contains(["S", "N", "B"], var.hash_key_type)
    error_message = "hash_key_type must be S, N, or B."
  }
}

variable "range_key" {
  description = "Optional sort key attribute name."
  type        = string
  default     = null
}

variable "range_key_type" {
  description = "Sort key type: S, N, or B."
  type        = string
  default     = "S"

  validation {
    condition     = contains(["S", "N", "B"], var.range_key_type)
    error_message = "range_key_type must be S, N, or B."
  }
}

variable "billing_mode" {
  description = "PAY_PER_REQUEST (on-demand) or PROVISIONED."
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.billing_mode)
    error_message = "billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "read_capacity" {
  description = "Read capacity units (PROVISIONED only)."
  type        = number
  default     = 5
}

variable "write_capacity" {
  description = "Write capacity units (PROVISIONED only)."
  type        = number
  default     = 5
}

variable "enable_point_in_time_recovery" {
  description = "Continuous backups with restore to any second in the last 35 days."
  type        = bool
  default     = true
}

variable "ttl_attribute" {
  description = "Attribute holding an expiry epoch timestamp. Null disables TTL."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "Customer managed KMS key ARN. Null uses the AWS managed key for DynamoDB."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Block table deletion (turn on for production)."
  type        = bool
  default     = false
}

variable "stream_view_type" {
  description = "Enable DynamoDB Streams with this view type (KEYS_ONLY, NEW_IMAGE, OLD_IMAGE, NEW_AND_OLD_IMAGES). Null disables streams."
  type        = string
  default     = null

  validation {
    condition     = var.stream_view_type == null || try(contains(["KEYS_ONLY", "NEW_IMAGE", "OLD_IMAGE", "NEW_AND_OLD_IMAGES"], var.stream_view_type), false)
    error_message = "stream_view_type must be null, KEYS_ONLY, NEW_IMAGE, OLD_IMAGE or NEW_AND_OLD_IMAGES."
  }
}
