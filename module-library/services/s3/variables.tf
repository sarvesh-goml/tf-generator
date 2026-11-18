variable "name_prefix" {
  description = "Prefix used for naming every resource in this module."
  type        = string
}

variable "tags" {
  description = "Extra tags to add to resources (provider default_tags are applied on top)."
  type        = map(string)
  default     = {}
}

variable "bucket_name" {
  description = "Globally unique bucket name. Null generates a unique name from name_prefix."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete the bucket even when it contains objects."
  type        = bool
  default     = false
}

variable "enable_versioning" {
  description = "Keep previous versions of objects."
  type        = bool
  default     = true
}

variable "sse_algorithm" {
  description = "Default encryption: AES256 (S3 managed) or aws:kms."
  type        = string
  default     = "AES256"

  validation {
    condition     = contains(["AES256", "aws:kms"], var.sse_algorithm)
    error_message = "sse_algorithm must be AES256 or aws:kms."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN when sse_algorithm = aws:kms (null uses the AWS managed key)."
  type        = string
  default     = null
}

variable "noncurrent_version_expiration_days" {
  description = "Delete old object versions after this many days. Null keeps them forever."
  type        = number
  default     = 90
}

variable "transition_to_ia_days" {
  description = "Move objects to the cheaper Standard-IA storage class after this many days (minimum 30). Null keeps everything in Standard."
  type        = number
  default     = null

  validation {
    condition     = var.transition_to_ia_days == null || try(var.transition_to_ia_days >= 30, false)
    error_message = "transition_to_ia_days must be null or at least 30 (an AWS minimum for Standard-IA)."
  }
}
