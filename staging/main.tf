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

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_security_group" "alb_sg" {
  name        = "sockshop-staging-alb-sg"
  description = "Allow HTTP from internet to ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "k3s_sg" {
  name        = "sockshop-staging-k3s-sg"
  description = "k3s node security group"
  vpc_id      = var.vpc_id

  ingress {
    description = "all internal traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description     = "all traffic from bastion"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [var.bastion_security_group]
  }

  ingress {
    description     = "ALB to nginx ingress NodePort"
    from_port       = 30080
    to_port         = 30080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH from bastion CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.bastion_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "k3s_server" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.master_instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
  }

  tags = {
    Name = "sockshop-staging-k3s-server"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -eux

    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644" sh -

    until kubectl get node; do
      sleep 5
    done

    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/baremetal/deploy.yaml

    until kubectl -n ingress-nginx get svc ingress-nginx-controller; do
      sleep 5
    done

    kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{
      "spec": {
        "type": "NodePort",
        "ports": [
          {"name":"http","port":80,"protocol":"TCP","targetPort":"http","nodePort":30080},
          {"name":"https","port":443,"protocol":"TCP","targetPort":"https","nodePort":30443}
        ]
      }
    }' || true
  EOF
}

resource "aws_lb" "staging_alb" {
  name               = "sockshop-staging-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = var.public_subnet_ids
}

resource "aws_lb_target_group" "nginx_tg" {
  name        = "sockshop-staging-tg"
  port        = 30080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    port                = "30080"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }
}

resource "aws_lb_target_group_attachment" "server_attach" {
  target_group_arn = aws_lb_target_group.nginx_tg.arn
  target_id        = aws_instance.k3s_server.id
  port             = 30080
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.staging_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx_tg.arn
  }
}
