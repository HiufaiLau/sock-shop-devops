variable "aws_region" {
  description = "AWS region the staging stack runs in"
  type        = string
  default     = "eu-central-1"
}

variable "env" {
  description = "Environment name (must match staging/variables.tf)"
  type        = string
  default     = "staging"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the role, as owner/name"
  type        = string
  default     = "HiufaiLau/sock-shop-devops"
}

variable "github_environment" {
  description = "GitHub Environment the deploy job runs in (cd.yml `environment:`)"
  type        = string
  default     = "staging"
}

variable "state_bucket" {
  description = "S3 bucket holding Terraform state and deploy bundles"
  type        = string
  default     = "sockshop-terraform-state-414772274298"
}

variable "lock_table" {
  description = "DynamoDB table used for Terraform state locking"
  type        = string
  default     = "sockshop-terraform-locks"
}
