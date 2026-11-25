# AWS Credentials Setup

Staging runs in AWS account `414772274298`, region `eu-central-1` (Frankfurt).
There are two kinds of AWS access, and they use different credentials:

| Who | How they get AWS access | Stored keys? |
|-----|-------------------------|--------------|
| **CD (GitHub Actions)** | GitHub OIDC: assumes the `sockshop-staging-github-deploy` role | No |
| **You, from a laptop** | AWS CLI profile (IAM Identity Center or an IAM user) | Only on your machine |

## GitHub Actions (CD)

CD does **not** use access keys. Each run gets temporary credentials (valid for up
to 1 hour) through GitHub OIDC. The role, its trust policy and its permissions are
defined in [staging/github-oidc/](staging/github-oidc/README.md).

What GitHub needs:

- An environment called `staging` (**Settings → Environments**).
- In that environment, the **variable** (not secret) `AWS_DEPLOY_ROLE_ARN`, set to
  the output of:

  ```bash
  cd staging/github-oidc
  terraform output -raw deploy_role_arn
  ```

Do **not** add `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` or `AWS_REGION` secrets.
If they still exist from the old setup, delete them.

If CD fails with `AccessDenied`, the deploy role is missing a permission. Add it in
[staging/github-oidc/main.tf](staging/github-oidc/main.tf) and re-apply that stack
by hand (see below). CD can't change its own permissions.

## Local access

You need local credentials for:

- running Terraform by hand (for example `terraform plan` in `staging/`),
- applying `staging/github-oidc/` (needs IAM admin rights; CD never applies it),
- opening an SSM session or port-forwarding to Grafana/Prometheus.

### Recommended: IAM Identity Center (SSO)

Short-lived credentials, no keys on disk:

```bash
aws configure sso --profile sockshop
# SSO region: the region your Identity Center lives in
# Default region: eu-central-1

aws sso login --profile sockshop
export AWS_PROFILE=sockshop
```

### Alternative: IAM user with access keys

If Identity Center isn't set up, use an IAM user (**never the root user**) and
store its keys in a named profile:

```bash
aws configure --profile sockshop
# AWS Access Key ID / Secret Access Key: from IAM → Users → <user> → Security credentials
# Default region name: eu-central-1
# Default output format: json

export AWS_PROFILE=sockshop
```

Keep keys out of shell rc files and out of Git. Enable MFA on the user and rotate
the keys regularly.

### Verify

```bash
aws sts get-caller-identity
```

`Account` must be `414772274298`. If it shows another account, you're using the
wrong profile; set `AWS_PROFILE=sockshop`.

## Permissions

| Task | Needs |
|------|-------|
| `terraform plan/apply` in `staging/` | Same as the CD deploy role: EC2/VPC, ELB, ACM, CloudWatch, Route 53, SSM, the k3s node role, plus the state bucket and lock table |
| `terraform apply` in `staging/github-oidc/` | IAM admin (creates the OIDC provider and the deploy role) |
| SSM session / port forwarding | `ssm:StartSession` on the instance, plus the Session Manager plugin |

The full list of what CD is allowed to do is in
[staging/github-oidc/README.md](staging/github-oidc/README.md#permissions).

## Troubleshooting

### "Unable to locate credentials" / "No valid credential sources found"
Set `AWS_PROFILE=sockshop`, and run `aws sso login --profile sockshop` if you use SSO.

### "ExpiredToken"
Your SSO session expired. Run `aws sso login --profile sockshop`.

### `AccessDenied` locally
Check `aws sts get-caller-identity`: wrong account or wrong user is the usual cause.

### `AccessDenied` in CD
See [GitHub Actions (CD)](#github-actions-cd) above.

### CD fails at "Configure AWS credentials" with "Not authorized to perform sts:AssumeRoleWithWebIdentity"
- `AWS_DEPLOY_ROLE_ARN` is missing or wrong in the `staging` environment.
- The job isn't running with `environment: staging`, so the token's `sub` claim
  doesn't match the trust policy.
- The repo was renamed or moved; update `github_repo` in
  [staging/github-oidc/variables.tf](staging/github-oidc/variables.tf) and re-apply.
