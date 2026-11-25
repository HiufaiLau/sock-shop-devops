# GitHub OIDC deploy role

CD ([cd.yml](../../.github/workflows/cd.yml)) gets AWS access through GitHub OIDC.
Each run receives temporary credentials (valid for up to 1 hour) for the
`sockshop-staging-github-deploy` role. No AWS keys are stored in GitHub.

Only a job in this repo running in the GitHub `staging` environment can assume
the role. The trust policy matches the token's `sub` claim:
`repo:HiufaiLau/sock-shop-devops:environment:staging`.

This stack is applied **by hand with admin credentials**. CD never applies it,
so the deploy role cannot change its own permissions.

## Setup (one time)

```bash
cd staging/github-oidc
terraform init
terraform apply
terraform output -raw deploy_role_arn
```

If the account already has a provider for `token.actions.githubusercontent.com`,
`apply` fails with `EntityAlreadyExists`. In that case, import the existing
provider and apply again:

```bash
terraform import aws_iam_openid_connect_provider.github \
  arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
```

In GitHub, go to **Settings → Environments → staging → Environment variables**
and add `AWS_DEPLOY_ROLE_ARN` with the ARN from `terraform output`. It is a
variable, not a secret, because a role ARN is not sensitive.

Then run **CD (Deploy)** manually once to confirm it works. After that:

1. Delete the `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_REGION`
   secrets from GitHub.
2. Deactivate, then delete, the access keys of the IAM user that CD used before.

## Permissions

The role's inline policy covers what CD does:

- **Terraform state:** read and write the state object, plus the DynamoDB lock table.
- **Manifest bundle:** read, write and delete objects under `deploy-bundles/staging/`.
- **Staging resources** (EC2/VPC, ELB, ACM, CloudWatch), limited to `eu-central-1`.
- **Route 53:** manage records (Route 53 is global, so it has no region limit).
- **SSM:** send the deploy command and read its output.
- **IAM:** only the k3s node's `sockshop-staging-k3s-server-*` role and
  instance profile. The only policy it can attach to them is
  `AmazonSSMManagedInstanceCore`, so the deploy role cannot grant anyone admin.

If `staging/main.tf` starts using a new AWS service, CD will fail with
`AccessDenied`. Add the missing actions here and re-apply this stack.
