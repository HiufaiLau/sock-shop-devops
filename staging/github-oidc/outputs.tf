output "deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN variable on the GitHub `staging` environment"
  value       = aws_iam_role.github_deploy.arn
}

output "dlm_role_arn" {
  description = "Role Data Lifecycle Manager uses for the daily snapshots (referenced by staging/main.tf)"
  value       = aws_iam_role.dlm.arn
}
