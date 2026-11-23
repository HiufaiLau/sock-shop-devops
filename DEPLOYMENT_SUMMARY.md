# Sock Shop AWS Deployment - Summary

Staging runs Sock Shop on a single-node K3s cluster in AWS Frankfurt (eu-central-1),
deployed by Terraform and GitHub Actions. Full details: [staging/README.md](staging/README.md).

**App URL:** https://sockshop-staging.link

## Infrastructure ([staging/](staging/))

- **EC2**: one t3.medium (4 GiB RAM), Ubuntu 22.04 + K3s, with an Elastic IP
  - Runs the shop (`sock-shop` namespace) and Prometheus/Grafana (`monitoring` namespace)
  - A CloudWatch alarm stops the instance after 30 min idle (CPU < 5%); CD starts it again
- **Network**: custom VPC, 3 public subnets across AZs, Internet Gateway
- **ALB**: HTTPS via ACM, HTTP redirects to HTTPS, forwards to NodePort 30080
- **Route 53**: `sockshop-staging.link` alias to the ALB, DNS-validated certificate
- **Security**: the instance only accepts NodePort 30080 from the ALB. SSH (22) and the
  K3s API (6443) are closed; all admin and CI access goes through AWS SSM

Resource IDs (instance, IPs, ALB DNS) change when infrastructure is recreated, so
read them from Terraform instead of copying them from docs:

```bash
cd sock-shop-devops/staging
terraform init
terraform output
```

## CI/CD

Pushing to the `staging` branch runs CI ([ci.yml](.github/workflows/ci.yml)): manifest
sync check, kubeconform + helm lint, and a kind smoke test. When CI is green it calls CD
([cd.yml](.github/workflows/cd.yml)), which runs `terraform apply`, starts the instance
if it was idle-stopped, and deploys the shop and monitoring manifests over SSM
([staging/ssm-run.sh](staging/ssm-run.sh) → [staging/remote-deploy.sh](staging/remote-deploy.sh)).

Manual redeploy: Actions → **CD (Deploy)** → Run workflow (branch `staging`).

GitHub secrets required: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` (eu-central-1).

## Accessing the Cluster

```bash
cd sock-shop-devops/staging
INSTANCE_ID=$(terraform output -raw server_instance_id)

# Shell on the node (needs the Session Manager plugin)
aws ssm start-session --target "$INSTANCE_ID"
sudo kubectl get pods -A
```

Grafana and Prometheus are only reachable through SSM port forwarding; see
[staging/README.md](staging/README.md#monitoring-prometheus--grafana).

## Cost Estimate

Running 24/7 (the idle alarm lowers the real EC2 cost):

- t3.medium EC2: ~$35/month
- Application Load Balancer: ~$20/month
- EBS storage (50 GB gp3): ~$5/month
- Elastic IP, Route 53 zone, data transfer: a few $/month
- **Total: ~$60-70/month**

## Deployment History

- **Apr 2026, t3.micro → t3.small** (local `terraform.tfvars` override): 1 GiB RAM was
  too small; the instance overloaded and SSM timed out.
- **Nov 2026, t3.large → t3.medium** (default in [staging/variables.tf](staging/variables.tf)):
  downsized to cut cost. If pods go `Pending`/`OOMKilled`, set
  `master_instance_type` back to `t3.large`.
- **Nov 2026, locked down**: closed SSH/6443, moved access to SSM, added HTTPS, deployed
  monitoring, gated CD on green CI.
- **Stale Elastic IP fix**: K3s advertised an old EIP, which broke in-cluster DNS and
  caused crash loops. K3s now advertises the node's private IP, and `remote-deploy.sh`
  enforces that on every deploy.

For known issues and fixes, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Cleanup

```bash
cd sock-shop-devops/staging
terraform destroy
```

**Warning**: this deletes all staging resources, including data.

## Related Docs

- [staging/README.md](staging/README.md): infrastructure, access, monitoring, troubleshooting
- [AWS_CREDENTIALS_SETUP.md](AWS_CREDENTIALS_SETUP.md): AWS credentials setup
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): past issues and fixes
