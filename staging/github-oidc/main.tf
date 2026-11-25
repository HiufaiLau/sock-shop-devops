# One-time bootstrap: lets GitHub Actions assume an AWS role via OIDC instead
# of using long-lived IAM user keys stored as GitHub secrets.
#
# Applied by hand with admin credentials, NOT by CD. Keeping it out of
# staging/ means the deploy role can never edit its own permissions.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "sockshop-terraform-state-414772274298"
    key            = "github-oidc/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "sockshop-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  name       = "sockshop-${var.env}"
  # Matches cd.yml: the job runs with `environment: staging`, so GitHub puts
  # the environment (not the branch) in the token's `sub` claim.
  github_sub = "repo:${var.github_repo}:environment:${var.github_environment}"
}

# --- OIDC identity provider ---------------------------------------------------
# Only one per account may exist for this URL. If it already exists, import it:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate against its own trusted CAs; these are
  # only kept because older provider versions require the field.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# --- Deploy role ----------------------------------------------------------------
resource "aws_iam_role" "github_deploy" {
  name                 = "${local.name}-github-deploy"
  description          = "Assumed by GitHub Actions CD (${var.github_repo}, env ${var.github_environment})"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_sub
        }
      }
    }]
  })

  tags = {
    Project     = "sock-shop"
    Environment = var.env
  }
}

# Everything cd.yml needs: Terraform state, staging/main.tf resources, the
# manifest bundle in S3, and SSM to run the deploy script on the node.
data "aws_iam_policy_document" "github_deploy" {
  # Terraform remote state + lock table
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }

  statement {
    sid     = "StateAndBundleObjects"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::${var.state_bucket}/${var.env}/terraform.tfstate",
      "arn:aws:s3:::${var.state_bucket}/${var.env}/terraform.tfstate.tflock",
      "arn:aws:s3:::${var.state_bucket}/deploy-bundles/${var.env}/*",
    ]
  }

  statement {
    sid       = "StateLock"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/${var.lock_table}"]
  }

  # Services managed by staging/main.tf, pinned to the staging region.
  # (Route 53 and ACM lookups are covered too; Route 53 is a global service,
  # so it is granted separately below without the region condition.)
  statement {
    sid = "StagingInfraRegional"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "acm:*",
      "cloudwatch:*",
      "ssm:SendCommand",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid = "Route53"
    actions = [
      "route53:ListHostedZones",
      "route53:GetHostedZone",
      "route53:ListTagsForResource",
      "route53:ListResourceRecordSets",
      "route53:ChangeResourceRecordSets",
      "route53:GetChange",
    ]
    resources = ["*"]
  }

  # staging/main.tf creates the k3s node's role + instance profile. Scope IAM
  # writes to those names so the deploy role cannot create or edit other roles.
  statement {
    sid = "NodeRoleManage"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.name}-k3s-server-*",
      "arn:aws:iam::${local.account_id}:instance-profile/${local.name}-k3s-server-*",
    ]
  }

  # Only the SSM managed policy may be attached to the node role, so this
  # role cannot grant itself (or the node) admin.
  statement {
    sid       = "NodeRoleAttachSsmOnly"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.name}-k3s-server-*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
    }
  }

  statement {
    sid       = "NodeRolePassToEc2"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.name}-k3s-server-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # The ALB needs its service-linked role the first time one is created.
  statement {
    sid       = "ElbServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "${local.name}-github-deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
