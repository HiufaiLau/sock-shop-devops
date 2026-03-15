variable "aws_region" {
  description = "AWS region"
  default     = "eu-west-1"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the k3s server"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the ALB"
  type        = list(string)
}

variable "bastion_security_group" {
  description = "Bastion security group ID"
  type        = string
}

variable "bastion_cidr_block" {
  description = "CIDR block for bastion/public admin access"
  type        = string
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "master_instance_type" {
  description = "EC2 instance type for k3s server"
  default     = "t3.large"
}
