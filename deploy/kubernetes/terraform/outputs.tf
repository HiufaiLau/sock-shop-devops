output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "node_public_ip" {
  value = aws_instance.k3s_node.public_ip
}
