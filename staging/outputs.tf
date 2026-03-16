output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "alb_dns_name" {
  value = aws_lb.staging_alb.dns_name
}

output "server_public_ip" {
  value = aws_instance.k3s_server.public_ip
}
