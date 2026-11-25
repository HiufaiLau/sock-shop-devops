variable "env" {
  description = "Environment name"
  type        = string
  default     = "staging"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "key_name" {
  description = "EC2 SSH key pair name (optional - only needed for direct SSH access)"
  type        = string
  default     = null
}

variable "master_instance_type" {
  description = "EC2 type for k3s server"
  type        = string
  default     = "t3.medium"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "azs" {
  description = "Availability zones"
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
}

variable "public_subnets_cidrs" {
  description = "CIDRs for public subnets"
  type        = list(string)
  default     = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
}

variable "k3s_version" {
  description = "K3s version to install"
  type        = string
  default     = "v1.27.3+k3s1"
}

variable "server_subnet_index" {
  description = "Which public subnet (0 = eu-central-1a, 1 = b, 2 = c) the k3s server runs in. Set by restore.sh; changing it alone does not move a running server."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 2], var.server_subnet_index)
    error_message = "server_subnet_index must be 0, 1 or 2."
  }
}

variable "restore_ami_id" {
  description = "Image to build the k3s server from when restoring a snapshot (set by restore.sh). Empty = fresh Ubuntu."
  type        = string
  default     = ""
}
