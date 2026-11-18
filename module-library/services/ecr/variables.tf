variable "name_prefix" {
  description = "Prefix used for naming every resource in this module."
  type        = string
}

variable "tags" {
  description = "Extra tags to add to resources (provider default_tags are applied on top)."
  type        = map(string)
  default     = {}
}

variable "repository_name" {
  description = "Repository name. Defaults to <name_prefix>-app (lowercased)."
  type        = string
  default     = null
}

variable "image_tag_mutability" {
  description = "IMMUTABLE (recommended: a tag always points at the same image) or MUTABLE (allows re-pushing tags like latest)."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "scan_on_push" {
  description = "Scan images for vulnerabilities when pushed."
  type        = bool
  default     = true
}

variable "encryption_type" {
  description = "AES256 or KMS."
  type        = string
  default     = "AES256"

  validation {
    condition     = contains(["AES256", "KMS"], var.encryption_type)
    error_message = "encryption_type must be AES256 or KMS."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN when encryption_type = KMS (null uses the AWS managed key)."
  type        = string
  default     = null
}

variable "keep_last_images" {
  description = "Lifecycle policy: keep only this many most recent images."
  type        = number
  default     = 30
}

variable "untagged_image_expiry_days" {
  description = "Lifecycle policy: delete untagged images after this many days."
  type        = number
  default     = 7
}

variable "force_delete" {
  description = "Allow terraform destroy to delete the repository even if it still contains images."
  type        = bool
  default     = false
}
