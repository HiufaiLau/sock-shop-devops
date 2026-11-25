output "deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN variable on the GitHub `staging` environment"
  value       = aws_iam_role.github_deploy.arn
}
