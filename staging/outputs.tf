output "server_public_ip" {
  value = aws_instance.k3s_server.public_ip
}

output "alb_dns_name" {
  value = aws_lb.staging_alb.dns_name
}
