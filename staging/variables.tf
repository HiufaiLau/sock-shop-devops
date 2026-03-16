variable "env" {
  description = "Environment name"
  type        = string
  default     = "staging"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "key_name" {
  description = "EC2 SSH key pair name"
  type        = string
}

variable "bastion_cidr_block" {
  description = "Your public IP in CIDR format for SSH"
  type        = string
}

variable "master_instance_type" {
  description = "EC2 type for k3s server"
  type        = string
  default     = "t3.large"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "azs" {
  description = "Availability zones"
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}

variable "public_subnets_cidrs" {
  description = "CIDRs for public subnets"
  type        = list(string)
  default     = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
}
