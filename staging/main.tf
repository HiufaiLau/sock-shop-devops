terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = "sockshop-${var.env}-vpc"
  cidr = var.vpc_cidr

  azs                = var.azs
  public_subnets     = var.public_subnets_cidrs
  enable_nat_gateway = false
  single_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Project     = "sock-shop"
    Environment = var.env
  }
}

# Data source for latest Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Security Group for K3s Server
resource "aws_security_group" "k3s_server" {
  name_prefix = "sockshop-${var.env}-k3s-server-"
  description = "Security group for K3s server"
  vpc_id      = module.vpc.vpc_id

  # No SSH (22) and no K3s API (6443) from the internet: CI/CD and admins
  # reach the node through AWS SSM. The only inbound traffic is the
  # front-end NodePort, and only from the load balancer.
  ingress {
    description     = "Sock Shop front-end NodePort from the ALB only"
    from_port       = 30080
    to_port         = 30080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Egress - allow all outbound
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "sockshop-${var.env}-k3s-server"
    Project     = "sock-shop"
    Environment = var.env
  }

  lifecycle {
    create_before_destroy = true
  }
}

# IAM Role for EC2 instance (for SSM access)
resource "aws_iam_role" "k3s_server" {
  name_prefix = "sockshop-${var.env}-k3s-server-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "sockshop-${var.env}-k3s-server"
    Project     = "sock-shop"
    Environment = var.env
  }
}

# Attach AWS managed SSM policy
resource "aws_iam_role_policy_attachment" "k3s_server_ssm" {
  role       = aws_iam_role.k3s_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM instance profile
resource "aws_iam_instance_profile" "k3s_server" {
  name_prefix = "sockshop-${var.env}-k3s-server-"
  role        = aws_iam_role.k3s_server.name

  tags = {
    Name        = "sockshop-${var.env}-k3s-server"
    Project     = "sock-shop"
    Environment = var.env
  }
}

# K3s Server EC2 Instance
resource "aws_instance" "k3s_server" {
  # restore.sh sets restore_ami_id (an image of the latest snapshot) and
  # server_subnet_index (which AZ). Normal applies use a fresh Ubuntu image in
  # the first subnet.
  ami                    = var.restore_ami_id != "" ? var.restore_ami_id : data.aws_ami.ubuntu.id
  instance_type          = var.master_instance_type
  subnet_id              = module.vpc.public_subnets[var.server_subnet_index]
  vpc_security_group_ids = [aws_security_group.k3s_server.id]
  iam_instance_profile   = aws_iam_instance_profile.k3s_server.name
  key_name               = var.key_name

  associate_public_ip_address = true

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true

    # Picked up by the daily snapshot policy (aws_dlm_lifecycle_policy.daily).
    tags = {
      Name        = "sockshop-${var.env}-k3s-server"
      Backup      = "sockshop-${var.env}"
      Project     = "sock-shop"
      Environment = var.env
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    k3s_version = var.k3s_version
  }))

  tags = {
    Name        = "sockshop-${var.env}-k3s-server"
    Project     = "sock-shop"
    Environment = var.env
  }

  # subnet_id is ignored so that after `make restore AZ=b` the next CD apply
  # (which uses the default subnet) does not move the server back.
  lifecycle {
    ignore_changes = [ami, user_data, subnet_id]
  }
}

# Elastic IP: stable public address for the instance (outbound traffic). Not used by K3s.
resource "aws_eip" "k3s_server" {
  domain = "vpc"

  tags = {
    Name        = "sockshop-${var.env}-k3s-server"
    Project     = "sock-shop"
    Environment = var.env
  }
}

resource "aws_eip_association" "k3s_server" {
  instance_id   = aws_instance.k3s_server.id
  allocation_id = aws_eip.k3s_server.id
}

# Application Load Balancer
resource "aws_lb" "staging_alb" {
  name               = "sockshop-${var.env}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = false

  tags = {
    Name        = "sockshop-${var.env}-alb"
    Project     = "sock-shop"
    Environment = var.env
  }
}

# Security Group for ALB
resource "aws_security_group" "alb" {
  name_prefix = "sockshop-${var.env}-alb-"
  description = "Security group for Application Load Balancer"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "sockshop-${var.env}-alb"
    Project     = "sock-shop"
    Environment = var.env
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Target Group for NodePort 30080
resource "aws_lb_target_group" "app" {
  name_prefix = "ssstg-"
  port        = 30080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200-399"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  tags = {
    Name        = "sockshop-${var.env}-app"
    Project     = "sock-shop"
    Environment = var.env
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Attach K3s server to target group
resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.k3s_server.id
  port             = 30080
}

# Route 53 hosted zone
data "aws_route53_zone" "main" {
  name         = "sockshop-staging.link"
  private_zone = false
}

# ACM Certificate
resource "aws_acm_certificate" "app" {
  domain_name       = "sockshop-staging.link"
  validation_method = "DNS"

  tags = {
    Name        = "sockshop-${var.env}"
    Project     = "sock-shop"
    Environment = var.env
  }

  lifecycle {
    create_before_destroy = true
  }
}

# DNS validation record
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Wait for certificate to be issued
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# Route 53 alias record → ALB
resource "aws_route53_record" "app" {
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = "sockshop-staging.link"
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_lb.staging_alb.dns_name
    zone_id                = aws_lb.staging_alb.zone_id
    evaluate_target_health = true
  }
}

# HTTP listener — redirect to HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.staging_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name        = "sockshop-${var.env}-http"
    Project     = "sock-shop"
    Environment = var.env
  }
}

# HTTPS listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.staging_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.app.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = {
    Name        = "sockshop-${var.env}-https"
    Project     = "sock-shop"
    Environment = var.env
  }
}

data "aws_caller_identity" "current" {}

# Auto-stop when CPU < 15% for 30 minutes (idle = nobody using the app).
# The idle floor is ~12-13% (K3s, Prometheus, the JVM services and bot
# traffic), so a lower threshold never fires. Measured Nov 2026 on t3.medium;
# re-check the CPUUtilization metric if the instance type or workload changes.
resource "aws_cloudwatch_metric_alarm" "idle_stop" {
  alarm_name          = "sockshop-${var.env}-idle-stop"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 6
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 15
  alarm_description   = "Stop instance after 30 min of idle (CPU < 15%)"

  alarm_actions = [
    "arn:aws:swf:${var.aws_region}:${data.aws_caller_identity.current.account_id}:action/actions/AWS_EC2.InstanceId.Stop/1.0"
  ]

  dimensions = {
    InstanceId = aws_instance.k3s_server.id
  }

  tags = {
    Project     = "sock-shop"
    Environment = var.env
  }
}

# Daily snapshot of the k3s server's disk at 03:00 UTC, 7 kept (~$2/month).
# Runs whether the instance is running or idle-stopped. Restore with
# `make restore AZ=a|b|c` (staging/restore.sh). The DLM role is created by the
# admin-applied github-oidc stack.
resource "aws_dlm_lifecycle_policy" "daily" {
  description        = "sockshop-${var.env} daily disk snapshots - 7 kept"
  execution_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/sockshop-${var.env}-dlm"
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      Backup = "sockshop-${var.env}"
    }

    schedule {
      name      = "daily-7-kept"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = 7
      }

      tags_to_add = {
        SnapshotCreator = "dlm"
      }
    }
  }

  tags = {
    Name        = "sockshop-${var.env}-daily-snapshots"
    Project     = "sock-shop"
    Environment = var.env
  }
}
