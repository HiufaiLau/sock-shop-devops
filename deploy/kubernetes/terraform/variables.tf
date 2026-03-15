variable "name" {
  description = "Base name for resources"
  type        = string
  default     = "sockshop"
}

variable "env" {
  description = "Environment name (staging|production)"
  type        = string
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "key_name" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "admin_cidr_blocks" {
  description = "CIDRs allowed to SSH to nodes (your office/home IP)"
  type        = list(string)
}
