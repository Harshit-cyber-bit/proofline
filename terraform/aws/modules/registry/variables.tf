variable "name" {
  description = "Name prefix for the repository."
  type        = string
}

variable "environment" {
  description = "Environment name, used in the repository name."
  type        = string
}

variable "untagged_expiry_days" {
  description = "Days before untagged images are expired. Untagged images are almost always overwritten build layers nobody can deploy."
  type        = number
  default     = 7
}
